"""fastapi-deprecation-response-headers validator.
Tests: deprecated routes emit Deprecation header, sunset/successor params work,
       middleware tracks deprecation hits.
"""
import sys, json, traceback

def main():
    results = {"task": "fastapi-deprecation-response-headers", "checks": {}}
    
    try:
        from fastapi import FastAPI, APIRouter
        from fastapi.testclient import TestClient
        results["checks"]["import_fastapi"] = True
    except Exception as e:
        results["checks"]["import_fastapi"] = False
        results["checks"]["import_fastapi_err"] = str(e)
        return results
    
    # T1: middleware module exists
    try:
        from fastapi.middleware.deprecation import DeprecationTrackingMiddleware
        results["checks"]["middleware_class"] = True
    except Exception as e:
        results["checks"]["middleware_class"] = False
        results["checks"]["middleware_class_err"] = str(e)
    
    # T2: deprecated=True emits Deprecation: true header
    try:
        app = FastAPI()
        
        @app.get("/old", deprecated=True)
        def old():
            return {"ok": True}
        
        client = TestClient(app)
        r = client.get("/old")
        dep = r.headers.get("Deprecation") or r.headers.get("deprecation")
        results["checks"]["deprecation_header_present"] = dep is not None
        results["checks"]["deprecation_header_value"] = dep
    except Exception as e:
        results["checks"]["deprecation_basic_err"] = f"{type(e).__name__}: {e}"
    
    # T3: sunset/successor_url params accepted
    try:
        import inspect
        from fastapi.routing import APIRoute
        sig = inspect.signature(APIRoute.__init__)
        results["checks"]["sunset_param"] = "sunset" in sig.parameters
        results["checks"]["successor_url_param"] = "successor_url" in sig.parameters
        results["checks"]["deprecation_date_param"] = "deprecation_date" in sig.parameters
    except Exception as e:
        results["checks"]["param_check_err"] = str(e)
    
    # T4: successor_url emits Link header
    try:
        app = FastAPI()
        
        @app.get("/v1/users", deprecated=True, successor_url="/v2/users")
        def users():
            return []
        
        client = TestClient(app)
        r = client.get("/v1/users")
        link = r.headers.get("Link") or r.headers.get("link")
        results["checks"]["link_header_present"] = link is not None
        results["checks"]["link_has_successor"] = link is not None and "successor-version" in link
        results["checks"]["link_header_value"] = link
    except Exception as e:
        results["checks"]["link_err"] = f"{type(e).__name__}: {e}"
    
    return results

if __name__ == "__main__":
    try:
        r = main()
    except Exception as e:
        r = {"task": "fastapi-deprecation-response-headers", "fatal": str(e), "traceback": traceback.format_exc()}
    print(json.dumps(r, indent=2))
