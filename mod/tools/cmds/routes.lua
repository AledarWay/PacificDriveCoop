local out = {}
for _, r in ipairs(FindAllOf("BaseRouteState") or {}) do Dev.out("route", Dev.name(r)) end
for _, c in ipairs(FindAllOf("ChartInstance") or {}) do Dev.out("chart", Dev.name(c)) end
return "ok"
