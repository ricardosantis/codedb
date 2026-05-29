"""langchain-request-coalescing validator.
Tests: Runnable.with_coalesce() exists, returns coalescing wrapper, and
       multiple concurrent calls with same input share one execution.
"""
import sys, json, traceback

def main():
    results = {"task": "langchain-request-coalescing", "checks": {}}
    
    # T1.1: import path exists
    try:
        from langchain_core.runnables import Runnable
        results["checks"]["import_runnable"] = True
    except Exception as e:
        results["checks"]["import_runnable"] = False
        results["checks"]["import_runnable_err"] = str(e)
        return results
    
    # T1.2: with_coalesce method exists
    try:
        assert hasattr(Runnable, "with_coalesce"), "Runnable.with_coalesce not defined"
        results["checks"]["with_coalesce_method"] = True
    except Exception as e:
        results["checks"]["with_coalesce_method"] = False
        results["checks"]["with_coalesce_method_err"] = str(e)
    
    # T1.3: new exports importable
    try:
        from langchain_core.runnables import CoalesceBackend, CoalesceStats, InMemoryCoalesceBackend
        results["checks"]["new_exports"] = True
    except Exception as e:
        results["checks"]["new_exports"] = False
        results["checks"]["new_exports_err"] = str(e)
    
    # T2: functional test — coalescing actually works
    try:
        from langchain_core.runnables import RunnableLambda
        import threading, time
        call_count = [0]
        def slow(x):
            call_count[0] += 1
            time.sleep(0.2)
            return x * 2
        r = RunnableLambda(slow).with_coalesce()
        results_list = []
        def caller():
            results_list.append(r.invoke(5))
        threads = [threading.Thread(target=caller) for _ in range(3)]
        for t in threads: t.start()
        for t in threads: t.join()
        assert all(x == 10 for x in results_list), f"results={results_list}"
        # Coalescing: 3 concurrent invokes with same key should share 1 execution
        results["checks"]["coalesce_works"] = call_count[0] < 3
        results["checks"]["call_count"] = call_count[0]
    except Exception as e:
        results["checks"]["coalesce_works"] = False
        results["checks"]["coalesce_works_err"] = f"{type(e).__name__}: {e}"
    
    return results

if __name__ == "__main__":
    try:
        r = main()
    except Exception as e:
        r = {"task": "langchain-request-coalescing", "fatal": str(e), "traceback": traceback.format_exc()}
    print(json.dumps(r, indent=2))
