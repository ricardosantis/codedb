"""fastapi-implicit-head-options validator.
Tests: auto_head/auto_options params exist on FastAPI/APIRouter, HEAD requests
       to GET routes return 200 with no body, OPTIONS returns method metadata.
"""
import sys, json, traceback

def main():
    results = {"task": "fastapi-implicit-head-options", "checks": {}}
    
    try:
        from fastapi import FastAPI, APIRouter
        results["checks"]["import_fastapi"] = True
    except Exception as e:
        results["checks"]["import_fastapi"] = False
        results["checks"]["import_fastapi_err"] = str(e)
        return results
    
    # T1: signature contains auto_head/auto_options
    import inspect
    try:
        sig = inspect.signature(FastAPI.__init__)
        results["checks"]["auto_head_in_FastAPI"] = "auto_head" in sig.parameters
        results["checks"]["auto_options_in_FastAPI"] = "auto_options" in sig.parameters
        rsig = inspect.signature(APIRouter.__init__)
        results["checks"]["auto_head_in_APIRouter"] = "auto_head" in rsig.parameters
        results["checks"]["auto_options_in_APIRouter"] = "auto_options" in rsig.parameters
    except Exception as e:
        results["checks"]["signature_err"] = str(e)
    
    # T2: middleware module exists
    try:
        from fastapi.middleware.methods import ImplicitMethodTrackingMiddleware
        results["checks"]["middleware_class"] = True
    except Exception as e:
        results["checks"]["middleware_class"] = False
        results["checks"]["middleware_class_err"] = str(e)
    
    # T3: functional — implicit HEAD works
    try:
        from fastapi.testclient import TestClient
        app = FastAPI()
        
        @app.get("/items")
        def items():
            return {"x": 1}
        
        client = TestClient(app)
        head_resp = client.head("/items")
        results["checks"]["head_status_200"] = head_resp.status_code == 200
        results["checks"]["head_no_body"] = len(head_resp.content) == 0
    except Exception as e:
        results["checks"]["head_functional_err"] = f"{type(e).__name__}: {e}"
    
    # T4: implicit OPTIONS
    try:
        from fastapi.testclient import TestClient
        app = FastAPI(auto_options=True)
        
        @app.get("/users")
        def users():
            return []
        
        @app.post("/users")
        def create():
            return {}
        
        client = TestClient(app)
        opt = client.options("/users")
        results["checks"]["options_status_200"] = opt.status_code == 200
        if opt.status_code == 200:
            body = opt.json()
            results["checks"]["options_has_path"] = body.get("path") == "/users"
            results["checks"]["options_has_methods"] = "methods" in body
            results["checks"]["options_has_operations"] = "operations" in body
            results["checks"]["options_allow_header"] = "Allow" in opt.headers or "allow" in opt.headers
    except Exception as e:
        results["checks"]["options_functional_err"] = f"{type(e).__name__}: {e}"
    
    return results

if __name__ == "__main__":
    try:
        r = main()
    except Exception as e:
        r = {"task": "fastapi-implicit-head-options", "fatal": str(e), "traceback": traceback.format_exc()}
    print(json.dumps(r, indent=2))
