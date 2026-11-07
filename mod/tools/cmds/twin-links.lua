-- Item -> manifestation links of the own car: per item, its manifestations in InventorySystem.ItemWorldStates and
-- which one GetActorManifestation returns; counts own-car parts vs parts on TWIN_CAR (global set by the caller).
local sys
for _, s in ipairs(FindAllOf("InventorySystem") or {}) do if s:IsValid() and not s:GetFullName():find("Default__", 1, true) then sys = s end end
local own = FindFirstOf("BP_CarManager_C").NewCarActor
for _, x in ipairs(FindAllOf("BP_PlayerCarNew_C") or {}) do if x:IsValid() and x:GetFullName():find(":PersistentLevel.", 1, true) and not (TWIN_CAR and TWIN_CAR:IsValid() and x:GetAddress() == TWIN_CAR:GetAddress()) then own = x end end
local function carOf(a)
  local cur, g = a, 0
  while cur and cur:IsValid() and g < 6 do
    local p = cur:GetAttachParentActor()
    if not (p and p:IsValid()) then return nil end
    if p:GetClass():GetFName():ToString() == "BP_PlayerCarNew_C" then return p end
    cur, g = p, g + 1
  end
end
local st = { items = 0, both = 0, curOwn = 0, curTwin = 0, curDead = 0, curOther = 0, arrDead = 0 }
sys.ItemWorldStates:ForEach(function(k, v)
  local inst = k:get()
  local arr = v:get().ActiveManifestations
  local hasOwn, hasTwin = false, false
  for i = 1, #arr do
    local a = arr[i]
    if a and a:IsValid() then
      local c = carOf(a)
      if c and c:GetAddress() == own:GetAddress() then hasOwn = true elseif c and TWIN_CAR and TWIN_CAR:IsValid() and c:GetAddress() == TWIN_CAR:GetAddress() then hasTwin = true end
    else st.arrDead = st.arrDead + 1 end
  end
  if hasOwn or hasTwin then
    st.items = st.items + 1
    if hasOwn and hasTwin then st.both = st.both + 1 end
    local m = inst:GetActorManifestation()
    if not (m and m:IsValid()) then st.curDead = st.curDead + 1
    else
      local c = carOf(m)
      if c and c:GetAddress() == own:GetAddress() then st.curOwn = st.curOwn + 1
      elseif c and TWIN_CAR and TWIN_CAR:IsValid() and c:GetAddress() == TWIN_CAR:GetAddress() then st.curTwin = st.curTwin + 1
      else st.curOther = st.curOther + 1 end
    end
  end
end)
return string.format("car items=%d in_both=%d current: own=%d twin=%d dead=%d other=%d | dead entries=%d", st.items, st.both, st.curOwn, st.curTwin, st.curDead, st.curOther, st.arrDead)
