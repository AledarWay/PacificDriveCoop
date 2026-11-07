-- Actors of the current world standing exactly at the origin: how many, per class, and what they look like
-- (root component, owner level, flags). Diagnoses the origin crowd after a leg travel.
local KSL = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
local gi = FindFirstOf("DrivingGameInstance")
local world = gi:GetWorld()
local level = world:GetFullName():gsub("^%S+ ", "") .. ":PersistentLevel."
local n, total, byClass, samples, worlds = 0, 0, {}, {}, {}
for _, a in ipairs(FindAllOf("Actor") or {}) do
    if a:IsValid() and KSL:IsValid(a) then
        local p = a:GetFullName()
        local w = p:match("^%S+ ([^:]+):") or "?"
        worlds[w] = (worlds[w] or 0) + 1
        if p:find(level, 1, true) then
            total = total + 1
            local ok, l = pcall(function() return a:K2_GetActorLocation() end)
            if ok and l and l.X == 0 and l.Y == 0 and l.Z == 0 then
                n = n + 1
                local c = a:GetClass():GetFName():ToString()
                byClass[c] = (byClass[c] or 0) + 1
                if #samples < 6 and c:find("FloatingRock") then
                    local rc = a.RootComponent
                    samples[#samples + 1] = string.format("%s root=%s hidden=%s", a:GetFName():ToString(),
                        tostring(rc and rc:IsValid()), tostring(a.bHidden))
                end
            end
        end
    end
end
local t = {}
for c, k in pairs(byClass) do t[#t + 1] = { c, k } end
table.sort(t, function(x, y) return x[2] > y[2] end)
local top = {}
for i = 1, math.min(8, #t) do top[#top + 1] = t[i][1] .. "=" .. t[i][2] end
local ws = {}
for w, k in pairs(worlds) do ws[#ws + 1] = w .. "=" .. k end
return string.format("world=%s actors=%d origin=%d | %s | %s | packages: %s", world:GetFName():ToString(), total, n,
    table.concat(top, " "), table.concat(samples, "; "), table.concat(ws, " "))
