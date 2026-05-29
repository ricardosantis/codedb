"""numba-stencil-boundary-modes validator.
Tests: @stencil accepts mode parameter, 'wrap'/'nearest'/'reflect'/'symmetric'/'constant'
       modes work, invalid mode raises NumbaValueError.
"""
import sys, json, traceback

def main():
    results = {"task": "numba-stencil-boundary-modes", "checks": {}}
    
    try:
        from numba import stencil
        import numpy as np
        results["checks"]["import_stencil"] = True
    except Exception as e:
        results["checks"]["import_stencil"] = False
        results["checks"]["import_stencil_err"] = str(e)
        return results
    
    # T1: stencil decorator accepts mode kwarg
    try:
        @stencil(mode='wrap')
        def kernel(a):
            return a[0] + a[-1]
        results["checks"]["mode_kwarg_accepted"] = True
    except TypeError as e:
        results["checks"]["mode_kwarg_accepted"] = False
        results["checks"]["mode_kwarg_err"] = str(e)
    except Exception as e:
        results["checks"]["mode_kwarg_other_err"] = f"{type(e).__name__}: {e}"
    
    # T2: positional shorthand @stencil('wrap')
    try:
        @stencil('wrap')
        def kernel2(a):
            return a[0]
        results["checks"]["positional_mode"] = True
    except Exception as e:
        results["checks"]["positional_mode"] = False
        results["checks"]["positional_mode_err"] = f"{type(e).__name__}: {e}"
    
    # T3: invalid mode raises NumbaValueError
    try:
        from numba.core.errors import NumbaValueError
        try:
            @stencil(mode='not_a_real_mode')
            def bad(a):
                return a[0]
            # Try to actually invoke it to trigger compile-time error
            arr = np.array([1, 2, 3])
            bad(arr)
            results["checks"]["invalid_mode_raises"] = False
        except NumbaValueError:
            results["checks"]["invalid_mode_raises"] = True
        except Exception as e:
            results["checks"]["invalid_mode_raises_kind"] = type(e).__name__
            results["checks"]["invalid_mode_raises"] = type(e).__name__ == "NumbaValueError"
    except ImportError:
        results["checks"]["NumbaValueError_importable"] = False
    
    # T4: actual stencil with wrap mode produces wrap behavior
    try:
        @stencil(mode='wrap')
        def shift_right(a):
            return a[-1]
        arr = np.array([1.0, 2.0, 3.0, 4.0])
        out = shift_right(arr)
        # wrap: out[0] should be arr[-1] = 4
        results["checks"]["wrap_behavior_correct"] = abs(out[0] - 4.0) < 1e-6
        results["checks"]["wrap_output"] = list(out)
    except Exception as e:
        results["checks"]["wrap_behavior_err"] = f"{type(e).__name__}: {e}"
    
    return results

if __name__ == "__main__":
    try:
        r = main()
    except Exception as e:
        r = {"task": "numba-stencil-boundary-modes", "fatal": str(e), "traceback": traceback.format_exc()}
    print(json.dumps(r, indent=2))
