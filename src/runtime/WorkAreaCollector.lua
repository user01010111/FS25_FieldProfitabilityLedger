-- FS25 single-player WorkArea collector. It is loaded as a vehicle
-- specialization by Register.lua and forwards only sealed root/update sets.

FieldProfitabilityLedger = FieldProfitabilityLedger or {}
FieldProfitabilityLedger.Runtime = FieldProfitabilityLedger.Runtime or {}

FieldProfitabilityLedgerCollector = FieldProfitabilityLedgerCollector or {}
local Specialization = FieldProfitabilityLedgerCollector
local Collector = {}

local listener = nil
local listenerToken = nil
local seenRoots = setmetatable({}, {__mode = "k"})
local completedMembers = setmetatable({}, {__mode = "k"})
local sealedRoots = setmetatable({}, {__mode = "k"})
local MAX_ROWS = 128

local OPERATIONS = {
    plow = "plowing",
    cultivator = "cultivating",
    mulcher = "mulching",
    stonepicker = "stonePicking",
    sowingmachine = "seedingPlanting",
    roller = "rolling",
    weeder = "mechanicalWeeding"
}

local SPRAY_OPERATIONS = {
    LIME = "lime",
    HERBICIDE = "herbicide",
    MANURE = "manure",
    LIQUIDMANURE = "slurry",
    SLURRY = "slurry",
    DIGESTATE = "digestate"
}

local function finite(value)
    return type(value) == "number" and value == value
        and value ~= math.huge and value ~= -math.huge
end

local function call(object, methodName, ...)
    if type(object) ~= "table" then return nil end
    local found, method = pcall(function() return object[methodName] end)
    if not found or type(method) ~= "function" then return nil end
    local ok, first, second, third = pcall(method, object, ...)
    if not ok then return nil end
    return first, second, third
end

local function stableId(object)
    local value = call(object, "getUniqueId")
    if type(value) ~= "string" or #value == 0 or #value > 64 then return nil end
    return value
end

local function rootVehicle(object)
    return call(object, "getRootVehicle") or object
end

local function workAreaMembers(root)
    local values, seen, count = {}, {}, 0
    local function add(value)
        if type(value) == "table" and not seen[value]
            and (type(rawget(value, "spec_workArea")) == "table"
                or type(rawget(value, "spec_vineCutter")) == "table") then
            count = count + 1
            if count > MAX_ROWS then return false end
            seen[value] = true
            values[count] = value
        end
        return true
    end
    if not add(root) then return nil end
    local children = rawget(root, "childVehicles")
    if type(children) == "table" then
        for index = 1, #children do
            if not add(children[index]) then return nil end
        end
    end
    return values
end

local function trackedMembers(root)
    local values, seen = {}, {}
    local function add(value)
        if type(value) == "table" and not seen[value]
            and (type(rawget(value, "spec_workArea")) == "table"
                or type(rawget(value, "spec_motorized")) == "table"
                or type(rawget(value, "spec_wearable")) == "table") then
            if #values >= MAX_ROWS then return false end
            seen[value] = true
            values[#values + 1] = value
        end
        return true
    end
    if not add(root) then return nil end
    local children = type(root) == "table" and rawget(root, "childVehicles") or nil
    if type(children) == "table" then
        for index = 1, #children do
            if not add(children[index]) then return nil end
        end
    end
    return values
end

local function currentSequence()
    local value = _G.g_updateLoopIndex
    if not finite(value) or value < 0 or value ~= math.floor(value) then return nil end
    return value
end

local function canSeal(root)
    local sequence = currentSequence()
    if sequence == nil then return nil, nil, nil, "sequenceUnavailable" end
    local members = workAreaMembers(root)
    local tracked = trackedMembers(root)
    if members == nil or #members == 0 or tracked == nil or #tracked == 0 then
        return nil, members, tracked, "memberTopologyUnavailable"
    end
    for _, member in ipairs(tracked) do
        if rawget(member, "isServer") ~= true then
            return nil, members, tracked, "trackedMemberNotServer"
        end
        if rawget(member, "updateLoopIndex") ~= sequence then
            return nil, members, tracked, "trackedMemberSequenceMismatch"
        end
    end
    return sequence, members, tracked
end

local function worldPoint(node)
    if node == nil or type(_G.getWorldTranslation) ~= "function" then
        return nil
    end
    local ok, x, _, z = pcall(getWorldTranslation, node)
    if not ok or not finite(x) or not finite(z) then return nil end
    return {x = x, z = z}
end

local function polygonAreaHa(points)
    if type(points) ~= "table" or #points < 3 then return nil end
    local origin = points[1]
    local twiceArea = 0
    for index = 2, #points - 1 do
        local first = points[index]
        local second = points[index + 1]
        local cross = (first.x - origin.x) * (second.z - origin.z)
            - (second.x - origin.x) * (first.z - origin.z)
        if not finite(cross) then return nil end
        twiceArea = twiceArea + cross
        if not finite(twiceArea) then return nil end
    end
    local areaHa = math.abs(twiceArea) / 20000
    return areaHa > 0 and areaHa or nil
end

local function farmlandSample(point)
    local manager = _G.g_farmlandManager
    if type(manager) ~= "table" then
        return nil
    end
    local farmlandId = call(manager, "getFarmlandIdAtWorldPosition", point.x, point.z)
    local ownerFarmId = call(manager, "getOwnerIdAtWorldPosition", point.x, point.z)
    if not finite(farmlandId) or not finite(ownerFarmId) then return nil end
    local sample = {farmlandId = farmlandId, ownerFarmId = ownerFarmId}
    local density = _G.FSDensityMapUtil
    local fieldData = type(density) == "table"
        and rawget(density, "getFieldDataAtWorldPosition") or nil
    if type(fieldData) == "function" then
        local ok, isOnField = pcall(fieldData, point.x, 0, point.z)
        if ok and type(isOnField) == "boolean" then
            sample.isFieldGround = isOnField
        end
    end
    return sample
end

local function fieldDescriptor(farmlandId)
    local manager = _G.g_fieldManager
    if type(manager) ~= "table" then return nil end
    local mapping = rawget(manager, "farmlandIdFieldMapping")
    local field = type(mapping) == "table" and rawget(mapping, farmlandId) or nil
    if type(field) ~= "table" then return nil end
    local fieldId = call(field, "getId")
    local nodes = call(field, "getPolygonPoints")
    if not finite(fieldId)
        or type(nodes) ~= "table" or #nodes < 3 or #nodes > 4096 then
        return nil
    end
    local polygon = {}
    for index = 1, #nodes do
        local point = worldPoint(nodes[index])
        if point == nil then return nil end
        polygon[index] = point
    end
    -- Derive the presentation/scenario basis from the same detached geometry
    -- that attribution validates instead of trusting optional cached metadata.
    local areaHa = polygonAreaHa(polygon)
    if areaHa == nil then return nil end
    return {
        fieldId = fieldId,
        farmlandId = farmlandId,
        areaHa = areaHa,
        polygon = polygon
    }
end

local function attributionSnapshotFromPoints(implement, start, width, height)
    if type(start) ~= "table" or type(width) ~= "table"
        or type(height) ~= "table" then return nil end
    local fourth = {
        x = width.x + height.x - start.x,
        z = width.z + height.z - start.z
    }
    local center = {
        x = (start.x + width.x + height.x + fourth.x) / 4,
        z = (start.z + width.z + height.z + fourth.z) / 4
    }
    local points = {start, width, fourth, height}
    local samples, farmlandIds = {}, {}
    for index, point in ipairs(points) do
        local sample = farmlandSample(point)
        if sample == nil then return nil end
        samples[index] = sample
        farmlandIds[sample.farmlandId] = true
    end
    local centerSample = farmlandSample(center)
    if centerSample == nil then return nil end
    farmlandIds[centerSample.farmlandId] = true

    local farmId = call(implement, "getActiveFarm")
    if not finite(farmId) then return nil end
    local fields = {}
    for farmlandId in pairs(farmlandIds) do
        local descriptor = fieldDescriptor(farmlandId)
        if descriptor ~= nil then fields[#fields + 1] = descriptor end
    end
    table.sort(fields, function(left, right)
        if left.farmlandId ~= right.farmlandId then
            return left.farmlandId < right.farmlandId
        end
        return left.fieldId < right.fieldId
    end)
    return {
        farmId = farmId,
        missionWork = false,
        workArea = {start = start, width = width, height = height},
        samples = samples,
        centerSample = centerSample,
        fields = fields
    }
end

local function attributionSnapshot(implement, workArea)
    local start = worldPoint(rawget(workArea, "start"))
    local width = worldPoint(rawget(workArea, "width"))
    local height = worldPoint(rawget(workArea, "height"))
    return attributionSnapshotFromPoints(implement, start, width, height)
end

local function localPoint(node, x, z)
    local transform = _G.localToWorld
    if node == nil or type(transform) ~= "function" then return nil end
    local ok, worldX, _, worldZ = pcall(transform, node, x, 0, z)
    if not ok or not finite(worldX) or not finite(worldZ) then return nil end
    return {x=worldX, z=worldZ}
end

-- Poplar uses TreePlanter:onUpdateTick rather than a SowingMachine WorkArea.
-- Reconstruct the exact one-pixel planting quadrilateral used by the installed
-- base function after it reports a positive lastWorkedArea. This reads the
-- completed result; it never calls a density-map mutation itself.
local function treePlanterAttributionSnapshot(implement)
    local spec = type(implement) == "table"
        and rawget(implement, "spec_treePlanter") or nil
    local mission = _G.g_currentMission
    local scale = call(mission, "getFruitPixelsToSqm")
    if type(spec) ~= "table" or rawget(spec, "node") == nil
        or not finite(scale) or scale <= 0 then return nil end
    local halfWidth = math.sqrt(scale) * 0.5
    local start = localPoint(spec.node, -halfWidth, -3 * halfWidth)
    local width = localPoint(spec.node, halfWidth, -3 * halfWidth)
    local height = localPoint(spec.node, -halfWidth, -halfWidth)
    return attributionSnapshotFromPoints(implement, start, width, height)
end

local function detectorPoint(value)
    if type(value) ~= "table" then return nil end
    local x = rawget(value, "x") or rawget(value, 1)
    local z = rawget(value, "z") or rawget(value, 3)
    if not finite(x) or not finite(z) then return nil end
    return {x=x, z=z}
end

-- Vine harvesters do not expose Cutter WorkAreas. Their authoritative
-- VineDetector retains the first/current raycast hits for the row segment
-- being handled. Convert that segment into a narrow detached quadrilateral;
-- harvested area and litres still come exclusively from Combine:addCutterArea.
local function vineAttributionSnapshot(implement)
    local detector = type(implement) == "table"
        and rawget(implement, "spec_vineDetector") or nil
    local cutter = type(implement) == "table"
        and rawget(implement, "spec_vineCutter") or nil
    local raycast = type(detector) == "table"
        and rawget(detector, "raycast") or nil
    if type(cutter) ~= "table" or type(raycast) ~= "table"
        or rawget(detector, "isVineDetectionActive") ~= true
        or (rawget(raycast, "currentNode") == nil
            and rawget(raycast, "vineNode") == nil) then
        return nil
    end
    local first = detectorPoint(rawget(raycast, "firstHitPosition"))
    local current = detectorPoint(rawget(raycast, "currentHitPosition"))
    if first == nil or current == nil then return nil end
    local dx, dz = current.x - first.x, current.z - first.z
    local length = math.sqrt(dx * dx + dz * dz)
    local px, pz = 0.25, 0
    if length > 0.001 then px, pz = -dz / length * 0.25, dx / length * 0.25 end
    local start = {x=first.x + px, z=first.z + pz}
    local width = {x=current.x + px, z=current.z + pz}
    local height = {x=first.x - px, z=first.z - pz}
    if length <= 0.001 then
        width = {x=first.x + px, z=first.z + 0.25}
        height = {x=first.x - px, z=first.z - 0.25}
    end
    local fourth = {
        x=width.x + height.x - start.x,
        z=width.z + height.z - start.z
    }
    local center = {
        x=(start.x + width.x + height.x + fourth.x) / 4,
        z=(start.z + width.z + height.z + fourth.z) / 4
    }
    local points = {start, width, fourth, height}
    local samples, farmlandIds = {}, {}
    for index, point in ipairs(points) do
        local sample = farmlandSample(point)
        if sample == nil then return nil end
        samples[index] = sample
        farmlandIds[sample.farmlandId] = true
    end
    local centerSample = farmlandSample(center)
    if centerSample == nil then return nil end
    farmlandIds[centerSample.farmlandId] = true
    local farmId = call(implement, "getActiveFarm")
    if not finite(farmId) then return nil end
    local fields = {}
    for farmlandId in pairs(farmlandIds) do
        local descriptor = fieldDescriptor(farmlandId)
        if descriptor ~= nil then fields[#fields + 1] = descriptor end
    end
    table.sort(fields, function(left, right)
        if left.farmlandId ~= right.farmlandId then
            return left.farmlandId < right.farmlandId
        end
        return left.fieldId < right.fieldId
    end)
    return {farmId=farmId, missionWork=false,
        workArea={start=start, width=width, height=height},
        samples=samples, centerSample=centerSample, fields=fields}
end

local function workAreaTypeName(workArea)
    local manager = _G.g_workAreaTypeManager
    local index = rawget(workArea, "type")
    local name = call(manager, "getWorkAreaTypeNameByIndex", index)
    return type(name) == "string" and string.lower(name) or nil
end

local function sprayOperation(implement)
    local spec = rawget(implement, "spec_sprayer")
    local parameters = type(spec) == "table"
        and rawget(spec, "workAreaParameters") or nil
    local fillType = type(parameters) == "table"
        and rawget(parameters, "sprayFillType") or nil
    local manager = _G.g_fillTypeManager
    local name = call(manager, "getFillTypeNameByIndex", fillType)
    if type(name) ~= "string" then return "fertilizer" end
    return SPRAY_OPERATIONS[string.upper(name)] or "fertilizer"
end

local function operationType(implement, typeName)
    if typeName == "sprayer" then return sprayOperation(implement) end
    if typeName == "cultivator" then
        local spec = rawget(implement, "spec_cultivator")
        if type(spec) == "table" then
            if rawget(spec, "isSubsoiler") == true then return "subsoiling" end
            if rawget(spec, "isPowerHarrow") == true then
                return "powerHarrowing"
            end
            if rawget(spec, "useDeepMode") == false then
                return "discHarrowing"
            end
        end
    end
    return OPERATIONS[typeName]
end

local function sowingChangedAreaHa(implement)
    local spec = type(implement) == "table"
        and rawget(implement, "spec_sowingMachine") or nil
    local parameters = type(spec) == "table"
        and rawget(spec, "workAreaParameters") or nil
    local changedArea = type(parameters) == "table"
        and rawget(parameters, "lastChangedArea") or nil
    if not finite(changedArea) or changedArea <= 0 then return nil end

    local mission = _G.g_currentMission
    local pixels = type(mission) == "table"
        and mission.getFruitPixelsToSqm or nil
    local mathUtil = _G.MathUtil
    local convert = type(mathUtil) == "table"
        and mathUtil.areaToHa or nil
    if type(pixels) ~= "function" or type(convert) ~= "function" then
        return nil
    end
    local okScale, scale = pcall(pixels, mission)
    if not okScale or not finite(scale) or scale <= 0 then return nil end
    local okArea, areaHa = pcall(convert, changedArea, scale)
    if not okArea or not finite(areaHa) or areaHa <= 0 then return nil end
    return areaHa
end

local function cropDescriptor(members)
    local selectedName, selectedId = nil, nil
    for _, implement in ipairs(members) do
        local spec = rawget(implement, "spec_sowingMachine")
        local parameters = type(spec) == "table"
            and rawget(spec, "workAreaParameters") or nil
        local fruitId = type(parameters) == "table"
            and rawget(parameters, "seedsFruitType") or nil
        if finite(fruitId) and fruitId >= 0
            and fruitId == math.floor(fruitId) then
            local name = call(_G.g_fruitTypeManager,
                "getFruitTypeNameByIndex", fruitId)
            if type(name) == "string" and #name > 0 and #name <= 128 then
                if selectedId ~= nil
                    and (selectedId ~= fruitId or selectedName ~= name) then
                    return nil, nil, "sowingCropCollision"
                end
                selectedName, selectedId = name, fruitId
            end
        end
        local treeSpec = rawget(implement, "spec_treePlanter")
        local workSpec = rawget(implement, "spec_workArea")
        local treeArea = type(workSpec) == "table"
            and rawget(workSpec, "lastWorkedArea") or nil
        if type(treeSpec) == "table" and finite(treeArea) and treeArea > 0 then
            local descriptor = call(_G.g_fruitTypeManager,
                "getFruitTypeByName", "POPLAR")
            local treeFruitId = type(descriptor) == "table"
                and rawget(descriptor, "index") or nil
            if not finite(treeFruitId) or treeFruitId < 0
                or treeFruitId ~= math.floor(treeFruitId) then
                return nil, nil, "treePlanterCropUnavailable"
            end
            if selectedId ~= nil
                and (selectedId ~= treeFruitId
                    or selectedName ~= "POPLAR") then
                return nil, nil, "sowingCropCollision"
            end
            selectedName, selectedId = "POPLAR", treeFruitId
        end
    end
    return selectedName or "unknown", selectedId
end

local function discriminator(implementId, workArea, typeName)
    local hash = 0
    for index = 1, #implementId do
        hash = (hash * 131 + string.byte(implementId, index)) % 2147483647
    end
    local areaIndex = rawget(workArea, "index")
    if not finite(areaIndex) or areaIndex < 1 then return nil end
    local value = string.format("wa-%08x-%d-%s", hash, areaIndex, typeName)
    return #value <= 64 and value or nil
end

local function treePlanterDiscriminator(implementId)
    local hash = 0
    for index = 1, #implementId do
        hash = (hash * 131 + string.byte(implementId, index)) % 2147483647
    end
    return string.format("tp-%08x", hash)
end

local function collectRows(members)
    local rows = {}
    for _, implement in ipairs(members) do
        local implementId = stableId(implement)
        local spec = rawget(implement, "spec_workArea")
        local workAreas = type(spec) == "table" and rawget(spec, "workAreas") or nil
        local vineOnly = type(rawget(implement, "spec_vineCutter")) == "table"
            and type(workAreas) ~= "table"
        if implementId == nil or (type(workAreas) ~= "table" and not vineOnly) then
            return nil, "invalidWorkAreaMember"
        end
        local sowingFallback = nil
        local sowingFallbackUsed = false
        for index = 1, type(workAreas) == "table" and #workAreas or 0 do
            local workArea = workAreas[index]
            local typeName = type(workArea) == "table"
                and workAreaTypeName(workArea) or nil
            local amount = type(workArea) == "table"
                and rawget(workArea, "lastWorkedHectares") or nil
            -- FS25's combined fertilizing sowing machines expose the
            -- authoritative changed density-map area through
            -- SowingMachine.workAreaParameters on builds where the generic
            -- WorkArea row has no positive hectare value. Convert it exactly
            -- once for that implement/update so a real sowing pass cannot
            -- disappear merely because the convenience cache is absent.
            if (not finite(amount) or amount <= 0)
                and typeName == "sowingmachine" and not sowingFallbackUsed then
                if sowingFallback == nil then
                    sowingFallback = sowingChangedAreaHa(implement) or false
                end
                if sowingFallback ~= false then
                    amount = sowingFallback
                    sowingFallbackUsed = true
                end
            end
            if finite(amount) and amount > 0 then
                local operation = typeName ~= nil
                    and operationType(implement, typeName) or nil
                if operation ~= nil then
                    local snapshot = attributionSnapshot(implement, workArea)
                    local token = discriminator(implementId, workArea, typeName)
                    if snapshot == nil or token == nil then
                        return nil, "snapshotUnavailable"
                    end
                    rows[#rows + 1] = {
                        attributionSnapshot = snapshot,
                        changedAreaHa = amount,
                        observationDiscriminator = token,
                        operationType = operation,
                        workAreaType = typeName
                    }
                    if #rows > MAX_ROWS then return nil, "tooManyRows" end
                end
            end
        end
        local treeSpec = rawget(implement, "spec_treePlanter")
        local treeArea = type(spec) == "table"
            and rawget(spec, "lastWorkedArea") or nil
        if type(treeSpec) == "table" and #workAreas == 0
            and finite(treeArea) and treeArea > 0 then
            local mission = _G.g_currentMission
            local scale = call(mission, "getFruitPixelsToSqm")
            local mathUtil = _G.MathUtil
            local convert = type(mathUtil) == "table"
                and rawget(mathUtil, "areaToHa") or nil
            local okArea, areaHa = false, nil
            if finite(scale) and scale > 0 and type(convert) == "function" then
                okArea, areaHa = pcall(convert, treeArea, scale)
            end
            local snapshot = treePlanterAttributionSnapshot(implement)
            local token = treePlanterDiscriminator(implementId)
            if not okArea or not finite(areaHa) or areaHa <= 0
                or snapshot == nil or #token > 64 then
                return nil, "treePlanterSnapshotUnavailable"
            end
            rows[#rows + 1] = {
                attributionSnapshot = snapshot,
                changedAreaHa = areaHa,
                observationDiscriminator = token,
                operationType = "seedingPlanting",
                workAreaType = "treeplanter"
            }
            if #rows > MAX_ROWS then return nil, "tooManyRows" end
        end
    end
    return rows
end

local function implementIds(members)
    local result = {}
    for _, member in ipairs(members) do
        local id = stableId(member)
        if id == nil then return nil end
        result[#result + 1] = id
    end
    table.sort(result)
    return result
end

local function collectImpl(root, dt)
    local sequence, members = canSeal(root)
    if sequence == nil then return nil, "updateNotSealed" end
    local rootId = stableId(root)
    local ids = implementIds(members)
    local rows, rowReason = collectRows(members)
    local fruitType, fruitTypeId, fruitReason = cropDescriptor(members)
    local mission = _G.g_currentMission
    local environment = type(mission) == "table" and rawget(mission, "environment") or nil
    local missionTime = type(mission) == "table" and rawget(mission, "time") or nil
    local period = type(environment) == "table" and rawget(environment, "currentPeriod") or nil
    if rootId == nil or ids == nil or rows == nil or fruitType == nil
        or not finite(dt) or dt < 0
        or not finite(missionTime) or not finite(period) then
        return nil, rowReason or fruitReason or "runtimeContextUnavailable"
    end
    -- FS25 1.20 exposes the locally controlled vehicle through Player. The
    -- mission-level controlledVehicle field used by older integrations is not
    -- populated by the active FS25 runtime.
    local controlled = call(_G.g_localPlayer, "getCurrentVehicle")
    local aiActive = call(root, "getIsAIActive")
    local playerActive = controlled ~= nil
        and rawequal(rootVehicle(controlled), root)
    local operatorKind = aiActive == true and "ai"
        or (playerActive and "player" or "unknown")
    local operatorId = nil
    if operatorKind == "ai" then
        local aiSpec = rawget(root, "spec_aiJobVehicle")
        local helper = type(aiSpec) == "table" and rawget(aiSpec, "currentHelper") or nil
        local helperIndex = type(helper) == "table" and rawget(helper, "index") or nil
        if finite(helperIndex) and helperIndex >= 0
            and helperIndex == math.floor(helperIndex) then
            operatorId = "helper-" .. tostring(helperIndex)
        end
    elseif operatorKind == "player" then
        local enterable = rawget(root, "spec_enterable")
        local controller = type(enterable) == "table"
            and rawget(enterable, "controllerUserId") or nil
        if (type(controller) == "string" and #controller > 0)
            or (finite(controller) and controller >= 0
                and controller == math.floor(controller)) then
            local candidate = "user-" .. tostring(controller)
            if #candidate <= 64 then operatorId = candidate end
        end
    end
    return {
        activeMs = dt,
        complete = true,
        implementIds = ids,
        missionTime = missionTime,
        operatorId = operatorId,
        operatorKind = operatorKind,
        operatorQuality = operatorKind == "player" and "Partial" or "Partial",
        period = period,
        qualityClass = "Complete",
        reasons = {},
        rootVehicleId = rootId,
        rows = rows,
        serverSequence = sequence,
        fruitType = fruitType,
        fruitTypeId = fruitTypeId
    }
end

function Collector.collect(root, dt)
    local sequence = currentSequence()
    if sequence == nil or sealedRoots[root] ~= sequence then
        return nil, "updateNotSealed"
    end
    local update, reason = collectImpl(root, dt)
    if update == nil then
        -- The runtime needs the exact observer key even when collection fails
        -- before an update DTO exists. Extra Lua returns are internal to that
        -- port; ordinary two-result callers remain unchanged.
        return nil, reason, stableId(root), sequence
    end
    return update
end

-- Deterministic non-dispatching collection entry. Normal runtime collection
-- uses collect, which also requires the full late-listener completion barrier.
function Collector.collectForTest(root, dt)
    return collectImpl(root, dt)
end

-- Completion-barrier entry for work invoked after the vehicle's normal
-- late-update callback in the same frame. It opens the sealed collection
-- window around the installed listener without changing engine work or
-- attribution data.
function Collector.dispatchForTest(root, dt)
    if listener == nil or type(root) ~= "table"
        or rawget(root, "isServer") ~= true then
        return nil, "collectorUnavailable"
    end
    local sequence = currentSequence()
    if sequence == nil then return nil, "sequenceUnavailable" end
    sealedRoots[root] = sequence
    local ok, result, reason = pcall(listener, root, dt)
    sealedRoots[root] = nil
    if not ok then return nil, "listenerFailure" end
    return result, reason
end

-- Detached geometry seam used only while the same root/update is sealed.
-- Harvest wrappers may retain a header reference until this call, but no
-- engine object is returned beyond the barrier.
function Collector.collectAttributionSnapshots(implement)
    if type(implement) ~= "table" or rawget(implement, "isServer") ~= true then
        return nil, "invalidHarvestHeader"
    end
    local spec = rawget(implement, "spec_workArea")
    local workAreas = type(spec) == "table" and rawget(spec, "workAreas") or nil
    if type(workAreas) ~= "table" or #workAreas == 0 then
        local snapshot = vineAttributionSnapshot(implement)
        if snapshot == nil then return nil, "invalidHarvestHeader" end
        return {snapshot}
    end
    if #workAreas > MAX_ROWS then return nil, "invalidHarvestHeader" end
    local result = {}
    for index = 1, #workAreas do
        local workArea = workAreas[index]
        if type(workArea) == "table"
            and workAreaTypeName(workArea) == "cutter" then
            local snapshot = attributionSnapshot(implement, workArea)
            if snapshot == nil then return nil, "snapshotUnavailable" end
            result[#result + 1] = snapshot
        end
    end
    if #result == 0 then return nil, "harvestWorkAreaUnavailable" end
    return result
end

-- Detached sowing geometry captured while the authoritative application
-- callback's root/update is still in flight. ApplicationRuntimeAdapter keeps
-- the engine reference only until its same-update augmentation barrier.
function Collector.collectSowingAttributionSnapshots(implement)
    if type(implement) ~= "table" or rawget(implement, "isServer") ~= true then
        return nil, "invalidSowingImplement"
    end
    local spec = rawget(implement, "spec_workArea")
    local workAreas = type(spec) == "table" and rawget(spec, "workAreas") or nil
    if type(workAreas) ~= "table" or #workAreas == 0
        or #workAreas > MAX_ROWS then return nil, "invalidSowingImplement" end
    local result = {}
    for index = 1, #workAreas do
        local workArea = workAreas[index]
        if type(workArea) == "table"
            and workAreaTypeName(workArea) == "sowingmachine" then
            local snapshot = attributionSnapshot(implement, workArea)
            if snapshot == nil then return nil, "snapshotUnavailable" end
            result[#result + 1] = snapshot
        end
    end
    if #result == 0 then return nil, "sowingWorkAreaUnavailable" end
    return result
end

-- Detached geometry for an exact application fact whose density-map update
-- changed no area.  This is deliberately separate from collectRows(): a zero
-- application area is land evidence for an unallocated audit fact, never a
-- WorkArea accounting row.  Combined fertilizing seeders may expose only the
-- generic sowing WorkArea, so that proven specialization pairing is accepted
-- for this read-only snapshot seam as well.
function Collector.collectApplicationAttributionSnapshots(implement)
    if type(implement) ~= "table" or rawget(implement, "isServer") ~= true
        or type(rawget(implement, "spec_sprayer")) ~= "table" then
        return nil, "invalidApplicationImplement"
    end
    local spec = rawget(implement, "spec_workArea")
    local workAreas = type(spec) == "table" and rawget(spec, "workAreas") or nil
    if type(workAreas) ~= "table" or #workAreas == 0
        or #workAreas > MAX_ROWS then
        return nil, "invalidApplicationImplement"
    end
    local combinedSowing = type(rawget(implement, "spec_sowingMachine"))
        == "table"
    local result = {}
    for index = 1, #workAreas do
        local workArea = workAreas[index]
        local typeName = type(workArea) == "table"
            and workAreaTypeName(workArea) or nil
        if typeName == "sprayer"
            or (combinedSowing and typeName == "sowingmachine") then
            local snapshot = attributionSnapshot(implement, workArea)
            if snapshot == nil then return nil, "snapshotUnavailable" end
            result[#result + 1] = snapshot
        end
    end
    if #result == 0 then return nil, "applicationWorkAreaUnavailable" end
    return result
end

function Collector.register(listenerValue)
    if type(listenerValue) ~= "function" or listener ~= nil then return nil end
    listener = listenerValue
    listenerToken = {}
    return listenerToken
end

function Collector.unregister(token)
    if token == nil or not rawequal(token, listenerToken) then return false end
    listener = nil
    listenerToken = nil
    return true
end

function Collector.reset()
    listener = nil
    listenerToken = nil
    seenRoots = setmetatable({}, {__mode = "k"})
    completedMembers = setmetatable({}, {__mode = "k"})
    sealedRoots = setmetatable({}, {__mode = "k"})
end

function Collector.dispatch(object, dt)
    if listener == nil or type(object) ~= "table"
        or rawget(object, "isServer") ~= true then return end
    local sequence = currentSequence()
    if sequence == nil then return end
    completedMembers[object] = sequence
    local root = rootVehicle(object)
    local sealedSequence, members = canSeal(root)
    if sealedSequence == nil then return end
    if seenRoots[root] == sequence then
        return
    end
    -- WorkArea processing is complete when every attached WorkArea member has
    -- reached this late listener. Motorized/Wearable-only members are still
    -- required by canSeal() to be authoritative and on the same engine
    -- sequence, but some vehicle roots do not dispatch this added
    -- specialization callback. Waiting for those unrelated callbacks can
    -- suppress an otherwise complete sowing batch forever.
    for _, member in ipairs(members) do
        if completedMembers[member] ~= sequence then
            return
        end
    end
    seenRoots[root] = sequence
    sealedRoots[root] = sequence
    local called, result = pcall(listener, root, dt)
    if not called and type(_G.print) == "function" then
        print("[FieldProfitabilityLedger] sealed listener failed: "
            .. tostring(result))
    end
    sealedRoots[root] = nil
end

function Specialization.prerequisitesPresent(specializations)
    if type(SpecializationUtil) ~= "table"
        or type(SpecializationUtil.hasSpecialization) ~= "function" then
        return false
    end
    return (type(_G.WorkArea) == "table"
            and SpecializationUtil.hasSpecialization(WorkArea, specializations))
        or (type(_G.Motorized) == "table"
            and SpecializationUtil.hasSpecialization(Motorized, specializations))
        or (type(_G.Wearable) == "table"
            and SpecializationUtil.hasSpecialization(Wearable, specializations))
        or (type(_G.FillUnit) == "table"
            and SpecializationUtil.hasSpecialization(FillUnit, specializations))
end

local function vehicleTypeHas(vehicleType, specialization)
    return type(specialization) == "table"
        and type(vehicleType) == "table"
        and type(rawget(vehicleType, "specializations")) == "table"
        and SpecializationUtil.hasSpecialization(
            specialization, vehicleType.specializations)
end

function Specialization.registerOverwrittenFunctions(vehicleType)
    local functions = type(vehicleType) == "table"
        and rawget(vehicleType, "functions") or nil
    if type(functions) ~= "table"
        or type(SpecializationUtil.registerOverwrittenFunction) ~= "function" then
        return
    end

    local runtime = FieldProfitabilityLedger.Runtime
    local harvest = type(runtime) == "table"
        and rawget(runtime, "HarvestRuntimeAdapter") or nil
    if vehicleTypeHas(vehicleType, _G.Combine)
        and type(rawget(functions, "addCutterArea")) == "function"
        and type(harvest) == "table"
        and type(harvest.observeVehicleCall) == "function"
        and type(harvest.registerVehicleBridge) == "function" then
        SpecializationUtil.registerOverwrittenFunction(
            vehicleType, "addCutterArea", Specialization.addCutterArea)
        harvest.registerVehicleBridge()
    end

    local application = type(runtime) == "table"
        and rawget(runtime, "ApplicationRuntimeAdapter") or nil
    if vehicleTypeHas(vehicleType, _G.FillUnit)
        and type(rawget(functions, "addFillUnitFillLevel")) == "function"
        and type(application) == "table"
        and type(application.observeFillUnitCall) == "function"
        and type(application.registerFillUnitBridge) == "function" then
        SpecializationUtil.registerOverwrittenFunction(
            vehicleType, "addFillUnitFillLevel",
            Specialization.addFillUnitFillLevel)
        application.registerFillUnitBridge()
    end

    local machinery = type(runtime) == "table"
        and rawget(runtime, "MachineryRuntimeAdapter") or nil
    if vehicleTypeHas(vehicleType, _G.Motorized)
        and type(rawget(functions, "updateConsumers")) == "function"
        and type(machinery) == "table"
        and type(machinery.observeVehicleCall) == "function"
        and type(machinery.registerVehicleBridge) == "function" then
        SpecializationUtil.registerOverwrittenFunction(
            vehicleType, "updateConsumers", Specialization.updateConsumers)
        machinery.registerVehicleBridge()
    end
end

function Specialization:addCutterArea(superFunc, ...)
    return FieldProfitabilityLedger.Runtime.HarvestRuntimeAdapter
        .observeVehicleCall(self, superFunc, ...)
end

function Specialization:addFillUnitFillLevel(superFunc, ...)
    return FieldProfitabilityLedger.Runtime.ApplicationRuntimeAdapter
        .observeFillUnitCall(self, superFunc, ...)
end

function Specialization:updateConsumers(superFunc, ...)
    return FieldProfitabilityLedger.Runtime.MachineryRuntimeAdapter
        .observeVehicleCall(self, superFunc, ...)
end

function Specialization.registerEventListeners(vehicleType)
    SpecializationUtil.registerEventListener(
        vehicleType, "onPostUpdateTick", Specialization)
end

function Specialization:onPostUpdateTick(dt)
    Collector.dispatch(self, dt)
end

FieldProfitabilityLedger.Runtime.WorkAreaCollector = Collector
return Collector
