"""textual-richlog-follow-state validator.
Tests: Log/RichLog expose is_following_end, follow_end(), and FollowChanged message.
"""
import sys, json, traceback

def main():
    results = {"task": "textual-richlog-follow-state", "checks": {}}
    
    try:
        from textual.widgets import Log, RichLog
        results["checks"]["import_widgets"] = True
    except Exception as e:
        results["checks"]["import_widgets"] = False
        results["checks"]["import_widgets_err"] = str(e)
        return results
    
    # T1: attributes/methods exist on both widgets
    for widget_cls in (Log, RichLog):
        name = widget_cls.__name__
        try:
            results["checks"][f"{name}_has_is_following_end"] = hasattr(widget_cls, "is_following_end")
            results["checks"][f"{name}_has_follow_end"] = hasattr(widget_cls, "follow_end")
        except Exception as e:
            results["checks"][f"{name}_attr_err"] = str(e)
    
    # T2: FollowChanged message class exists on either widget
    try:
        log_has = hasattr(Log, "FollowChanged")
        rich_has = hasattr(RichLog, "FollowChanged")
        results["checks"]["FollowChanged_message_log"] = log_has
        results["checks"]["FollowChanged_message_richlog"] = rich_has
        if log_has or rich_has:
            fc = getattr(Log, "FollowChanged", None) or getattr(RichLog, "FollowChanged", None)
            import inspect
            sig = inspect.signature(fc.__init__) if fc else None
            # Check expected attrs in carry: widget, is_following_end, scroll_y, max_scroll_y
            results["checks"]["FollowChanged_sig"] = str(sig) if sig else None
    except Exception as e:
        results["checks"]["FollowChanged_err"] = str(e)
    
    # T3: follow_end is callable
    try:
        import inspect
        for widget_cls in (Log, RichLog):
            name = widget_cls.__name__
            fe = getattr(widget_cls, "follow_end", None)
            if fe:
                sig = inspect.signature(fe)
                results["checks"][f"{name}_follow_end_sig"] = str(sig)
                results["checks"][f"{name}_follow_end_has_animate"] = "animate" in sig.parameters
    except Exception as e:
        results["checks"]["follow_end_sig_err"] = str(e)
    
    # T4: example file exists
    import os
    example_path = "/workspace/repo/examples/rich_log_follow_state.py"
    results["checks"]["example_file_exists"] = os.path.exists(example_path)
    if results["checks"]["example_file_exists"]:
        try:
            content = open(example_path).read()
            results["checks"]["example_has_RichLogFollowStateApp"] = "RichLogFollowStateApp" in content
            results["checks"]["example_has_follow_log_button"] = "follow-log" in content
            results["checks"]["example_has_main_guard"] = '__name__ == "__main__"' in content or "__name__ == '__main__'" in content
        except Exception as e:
            results["checks"]["example_read_err"] = str(e)
    
    return results

if __name__ == "__main__":
    try:
        r = main()
    except Exception as e:
        r = {"task": "textual-richlog-follow-state", "fatal": str(e), "traceback": traceback.format_exc()}
    print(json.dumps(r, indent=2))
