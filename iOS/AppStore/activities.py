import json, os, sys, time, urllib.request
token = os.environ["LYKTA_TOKEN"]
base = os.environ["LYKTA_URL"].rstrip("/") + "/v1/activities/"
now = int(time.time())

def call(method, name, body=None):
    req = urllib.request.Request(base + name, method=method, data=json.dumps(body).encode() if body else None,
                                 headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        raw = e.read(); return e.code, (json.loads(raw) if raw.strip().startswith(b"{") else {"message": raw.decode()[:300]})

ring = lambda color, value, label: {"zstack": [
    {"shape": "circle", "stroke": "quaternary", "lineWidth": 4},
    {"shape": "circle", "stroke": color, "lineWidth": 4, "lineCap": "round", "trim": [0, value], "modifiers": [{"rotation": -90}]},
    {"text": label, "modifiers": [{"font": 11}, {"fontWeight": "semibold"}, {"monospacedDigit": True}]}],
    "modifiers": [{"frame": {"width": 36, "height": 36}}]}
header = lambda symbol, color, caption, headline: [
    {"symbol": symbol, "modifiers": [{"font": "title2"}, {"foreground": color}]},
    {"vstack": [{"text": caption, "modifiers": [{"font": "caption"}, {"foreground": "secondary"}]},
                {"text": headline, "modifiers": [{"font": "headline"}, {"lineLimit": 1}]}],
     "alignment": "leading", "spacing": 2}]

tests = {
    "title": "Gateway tests", "relevance": 80, "alert": {"body": "Running gateway tests"},
    "data": {"done": 184, "total": 212, "fraction": 184 / 212, "percent": 87, "suite": "StoreTests"},
    "layout": {
        "lockScreen": {"vstack": [
            {"hstack": header("checkmark.seal.fill", "green", "Agent · lykta", "{{done}} of {{total}} tests passed")
                       + [{"spacer": True}, ring("green", 184 / 212, "{{percent}}%")], "spacing": 10},
            {"text": "Running {{suite}}", "modifiers": [{"font": "footnote"}, {"foreground": "secondary"}]}],
            "alignment": "leading", "spacing": 10, "modifiers": [{"padding": 16}]},
        "compactLeading": {"symbol": "checkmark.seal.fill", "modifiers": [{"foreground": "green"}]},
        "compactTrailing": {"text": "{{percent}}%", "modifiers": [{"monospacedDigit": True}, {"foreground": "green"}]},
        "minimal": {"gauge": "{{fraction}}", "style": "circular", "modifiers": [{"tint": "green"}]},
        "expanded": {
            "leading": {"hstack": [{"symbol": "checkmark.seal.fill", "modifiers": [{"foreground": "green"}]}, "Tests"], "spacing": 6,
                        "modifiers": [{"font": "headline"}, {"padding": {"leading": 6}}]},
            "trailing": {"text": "{{done}}/{{total}}", "modifiers": [{"font": "headline"}, {"monospacedDigit": True}, {"padding": {"trailing": 6}}]},
            "bottom": {"vstack": [{"progress": "{{fraction}}", "modifiers": [{"tint": "green"}]},
                                  {"text": "Running {{suite}}", "modifiers": [{"font": "caption"}, {"foreground": "secondary"}]}],
                       "alignment": "leading", "spacing": 6, "modifiers": [{"padding": {"horizontal": 6}}]}},
        "keyline": "green"}}

deploy = {
    "title": "Deploying gateway", "relevance": 100, "alert": {"body": "Deploying the gateway"},
    "data": {"start": now - 95, "end": now + 205, "step": "Rolling out to production"},
    "layout": {
        "lockScreen": {"vstack": [
            {"hstack": header("shippingbox.fill", "blue", "Agent · lykta-gateway", "{{step}}")
                       + [{"spacer": True},
                          {"timer": ["{{start}}", "{{end}}"], "modifiers": [{"font": "title2"}, {"fontWeight": "semibold"},
                           {"monospacedDigit": True}, {"multilineTextAlignment": "trailing"}, {"frame": {"width": 76}}]}],
             "spacing": 10},
            {"progress": ["{{start}}", "{{end}}"], "modifiers": [{"tint": "blue"}]}],
            "spacing": 12, "modifiers": [{"padding": 16}]},
        "compactLeading": {"symbol": "shippingbox.fill", "modifiers": [{"foreground": "blue"}]},
        "compactTrailing": {"progress": ["{{start}}", "{{end}}"], "style": "circular", "modifiers": [{"tint": "blue"}]},
        "minimal": {"progress": ["{{start}}", "{{end}}"], "style": "circular", "modifiers": [{"tint": "blue"}]},
        "expanded": {
            "leading": {"hstack": [{"symbol": "shippingbox.fill", "modifiers": [{"foreground": "blue"}]}, "Deploy"], "spacing": 6,
                        "modifiers": [{"font": "headline"}, {"padding": {"leading": 6}}]},
            "trailing": {"timer": ["{{start}}", "{{end}}"], "modifiers": [{"font": "headline"}, {"monospacedDigit": True},
                         {"multilineTextAlignment": "trailing"}, {"frame": {"width": 60}}, {"padding": {"trailing": 6}}]},
            "bottom": {"vstack": [{"progress": ["{{start}}", "{{end}}"], "modifiers": [{"tint": "blue"}]},
                                  {"text": "{{step}}", "modifiers": [{"font": "caption"}, {"foreground": "secondary"}]}],
                       "alignment": "leading", "spacing": 6, "modifiers": [{"padding": {"horizontal": 6}}]}},
        "keyline": "blue"}}

refactor = {
    "title": "Refactor", "relevance": 60, "alert": {"body": "Refactoring the delivery queue"},
    "data": {"started": now - 754, "step": 3, "steps": 5, "file": "Delivery.swift"},
    "layout": {
        "lockScreen": {"vstack": [
            {"hstack": header("sparkles", "orange", "Agent · lykta", "Refactoring delivery")
                       + [{"spacer": True},
                          {"date": "{{started}}", "style": "timer", "modifiers": [{"font": "title3"}, {"monospacedDigit": True},
                           {"multilineTextAlignment": "trailing"}, {"frame": {"width": 64}}]}], "spacing": 10},
            {"text": "Step {{step}} of {{steps}} · Editing {{file}}", "modifiers": [{"font": "footnote"}, {"foreground": "secondary"}]}],
            "alignment": "leading", "spacing": 10, "modifiers": [{"padding": 16}]},
        "compactLeading": {"symbol": "sparkles", "modifiers": [{"foreground": "orange"}]},
        "compactTrailing": {"text": "{{step}}/{{steps}}", "modifiers": [{"monospacedDigit": True}, {"foreground": "orange"}]},
        "minimal": {"symbol": "sparkles", "modifiers": [{"foreground": "orange"}]},
        "keyline": "orange"}}

quiet = "--quiet" in sys.argv
which = [a for a in sys.argv[1:] if a != "--quiet"] or ["deploy", "tests", "refactor"]
if quiet:
    [b.pop("alert", None) for b in (deploy, tests, refactor)]
for name in which:
    status, body = call("PUT", name, {"deploy": deploy, "tests": tests, "refactor": refactor}[name])
    print(name, status, body.get("delivery"), body.get("error"), body.get("message"))