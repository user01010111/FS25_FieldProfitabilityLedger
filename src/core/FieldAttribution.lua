-- Pure, detached field-attribution boundary.

FieldProfitabilityLedger = FieldProfitabilityLedger or {}
FieldProfitabilityLedger.Core = FieldProfitabilityLedger.Core or {}

local FieldAttribution = {}

local MAX_SAFE_INTEGER = 9007199254740991
local REQUIRED_VALIDATION = {
    "array",
    "asciiToken",
    "copy",
    "enum",
    "integer",
    "isFinite",
    "number",
    "text"
}
local REQUIRED_GEOMETRY = {
    "classifyQuadrilateral",
    "point",
    "pointRelation",
    "polygon",
    "quadrilateral",
    "segmentRelation"
}

local SNAPSHOT_KEYS = {
    centerSample = true,
    farmId = true,
    fields = true,
    missionWork = true,
    samples = true,
    workArea = true
}
local WORK_AREA_KEYS = {
    height = true,
    start = true,
    width = true
}
local POINT_KEYS = {
    x = true,
    z = true
}
local SAMPLE_KEYS = {
    farmlandId = true,
    isFieldGround = true,
    ownerFarmId = true
}
local FIELD_KEYS = {
    areaHa = true,
    farmlandId = true,
    fieldId = true,
    polygon = true
}

local function finiteNumber(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

local function positivePolicyInteger(value, maximum)
    return finiteNumber(value)
        and value == math.floor(value)
        and value >= 1
        and value <= maximum
end

local function unsignedByteLess(left, right)
    local sharedLength = math.min(#left, #right)
    for index = 1, sharedLength do
        local leftByte = string.byte(left, index)
        local rightByte = string.byte(right, index)
        if leftByte ~= rightByte then
            return leftByte < rightByte
        end
    end
    return #left < #right
end

local function snapshotPlainTable(value)
    if type(value) ~= "table" or getmetatable(value) ~= nil then
        return nil
    end
    local snapshot = {}
    local count = 0
    for key, item in next, value do
        snapshot[key] = item
        count = count + 1
    end
    return {value = value, items = snapshot, count = count}
end

local function tableMatchesSnapshot(snapshot)
    local value = snapshot.value
    if type(value) ~= "table" or getmetatable(value) ~= nil then
        return false
    end
    local count = 0
    for key, item in next, value do
        count = count + 1
        if not rawequal(rawget(snapshot.items, key), item) then
            return false
        end
    end
    return count == snapshot.count
end

local function exactPolicy(constants, limits, quality)
    return rawget(constants, "DEFAULT_EPSILON") == 0.000001
        and rawget(limits, "idBytes") == 64
        and rawget(limits, "textBytes") == 128
        and rawget(limits, "maxAreaHa") == 100000
        and rawget(limits, "maxWorldCoordinate") == 1000000
        and rawget(limits, "maxPolygonPoints") == 4096
        and rawget(limits, "maxGeometryEpsilon") == 1
        and rawget(limits, "maxBoundaryCandidates") == 16
        and rawget(limits, "maxNeutralDepth") == 32
        and rawget(limits, "maxNeutralItems") == 1000000
        and rawget(limits, "maxIdentifier") == MAX_SAFE_INTEGER
        and rawget(quality, "Complete") == "Complete"
        and rawget(quality, "Partial") == "Partial"
end

local function dependencyGraphMatches(context)
    if not rawequal(FieldProfitabilityLedger, context.root) then
        return false
    end
    if type(context.root) ~= "table" or getmetatable(context.root) ~= nil
        or not rawequal(rawget(context.root, "Core"), context.core) then
        return false
    end
    for index = 1, #context.snapshots do
        if not tableMatchesSnapshot(context.snapshots[index]) then
            return false
        end
    end
    return exactPolicy(context.constants, context.limits, context.quality)
end

local function dependencyBindingsMatch(context)
    local root = FieldProfitabilityLedger
    if not rawequal(root, context.root)
        or type(root) ~= "table" or getmetatable(root) ~= nil
        or not rawequal(rawget(root, "Core"), context.core)
        or type(context.core) ~= "table" or getmetatable(context.core) ~= nil
        or not rawequal(rawget(context.core, "Constants"), context.constants)
        or not rawequal(rawget(context.core, "Validation"), context.validation)
        or not rawequal(rawget(context.core, "Identifiers"), context.identifiers)
        or not rawequal(rawget(context.core, "Geometry"), context.geometry)
        or not rawequal(rawget(context.constants, "LIMITS"), context.limits)
        or not rawequal(rawget(context.constants, "QUALITY_CLASS"), context.quality)
        or getmetatable(context.constants) ~= nil
        or getmetatable(context.limits) ~= nil
        or getmetatable(context.quality) ~= nil then
        return false
    end
    return exactPolicy(context.constants, context.limits, context.quality)
end

local function resolveDependencies()
    local root = FieldProfitabilityLedger
    if type(root) ~= "table" or getmetatable(root) ~= nil then
        return nil, "constantsUnavailable"
    end
    local core = rawget(root, "Core")
    if type(core) ~= "table" or getmetatable(core) ~= nil then
        return nil, "constantsUnavailable"
    end

    local constants = rawget(core, "Constants")
    if type(constants) ~= "table" or getmetatable(constants) ~= nil then
        return nil, "constantsUnavailable"
    end
    local limits = rawget(constants, "LIMITS")
    local quality = rawget(constants, "QUALITY_CLASS")
    if type(limits) ~= "table" or getmetatable(limits) ~= nil
        or type(quality) ~= "table" or getmetatable(quality) ~= nil
        or not exactPolicy(constants, limits, quality) then
        return nil, "constantsUnavailable"
    end

    local validation = rawget(core, "Validation")
    if type(validation) ~= "table" or getmetatable(validation) ~= nil then
        return nil, "validationUnavailable"
    end
    for index = 1, #REQUIRED_VALIDATION do
        if type(rawget(validation, REQUIRED_VALIDATION[index])) ~= "function" then
            return nil, "validationUnavailable"
        end
    end

    local identifiers = rawget(core, "Identifiers")
    if type(identifiers) ~= "table" or getmetatable(identifiers) ~= nil
        or type(rawget(identifiers, "landKey")) ~= "function"
        or type(rawget(identifiers, "parseLandKey")) ~= "function" then
        return nil, "identifiersUnavailable"
    end

    local geometry = rawget(core, "Geometry")
    if type(geometry) ~= "table" or getmetatable(geometry) ~= nil then
        return nil, "geometryUnavailable"
    end
    for index = 1, #REQUIRED_GEOMETRY do
        if type(rawget(geometry, REQUIRED_GEOMETRY[index])) ~= "function" then
            return nil, "geometryUnavailable"
        end
    end

    local values = {
        root,
        core,
        constants,
        limits,
        quality,
        validation,
        identifiers,
        geometry
    }
    local snapshots = {}
    for index = 1, #values do
        snapshots[index] = snapshotPlainTable(values[index])
        if snapshots[index] == nil then
            return nil, index <= 5 and "constantsUnavailable"
                or (index == 6 and "validationUnavailable"
                    or (index == 7 and "identifiersUnavailable"
                        or "geometryUnavailable"))
        end
    end

    local validationFunctions = {}
    for index = 1, #REQUIRED_VALIDATION do
        local name = REQUIRED_VALIDATION[index]
        validationFunctions[name] = rawget(validation, name)
    end
    local geometryFunctions = {}
    for index = 1, #REQUIRED_GEOMETRY do
        local name = REQUIRED_GEOMETRY[index]
        geometryFunctions[name] = rawget(geometry, name)
    end
    local dependencyTables = {
        [root] = true,
        [core] = true,
        [constants] = true,
        [limits] = true,
        [quality] = true,
        [validation] = true,
        [identifiers] = true,
        [geometry] = true
    }

    return {
        root = root,
        core = core,
        constants = constants,
        limits = limits,
        quality = quality,
        validation = validation,
        identifiers = identifiers,
        geometry = geometry,
        validationFunctions = validationFunctions,
        geometryFunctions = geometryFunctions,
        identifierLandKey = rawget(identifiers, "landKey"),
        identifierParseLandKey = rawget(identifiers, "parseLandKey"),
        dependencyTables = dependencyTables,
        dependencyInputTables = setmetatable({}, {__mode = "k"}),
        dependencyOutputTables = setmetatable({}, {__mode = "k"}),
        outputRecords = {},
        callerTables = {},
        localTables = {},
        snapshots = snapshots,
        defaultEpsilon = rawget(constants, "DEFAULT_EPSILON"),
        idBytes = rawget(limits, "idBytes"),
        maxAreaHa = rawget(limits, "maxAreaHa"),
        maxBoundaryCandidates = rawget(limits, "maxBoundaryCandidates"),
        maxIdentifier = rawget(limits, "maxIdentifier"),
        maxNeutralDepth = rawget(limits, "maxNeutralDepth"),
        maxNeutralItems = rawget(limits, "maxNeutralItems"),
        maxPolygonPoints = rawget(limits, "maxPolygonPoints"),
        maxStringBytes = rawget(limits, "textBytes"),
        maxWorldCoordinate = rawget(limits, "maxWorldCoordinate"),
        complete = rawget(quality, "Complete"),
        partial = rawget(quality, "Partial")
    }
end

local function packValues(...)
    return {n = select("#", ...), ...}
end

local function markDependencyInput(context, value, seen)
    if type(value) ~= "table" then
        return
    end
    seen = seen or {}
    if seen[value] then
        return
    end
    seen[value] = true
    if context.callerTables[value] == true
        or context.localTables[value] == true
        or context.dependencyTables[value] == true
        or context.dependencyOutputTables[value] ~= nil then
        return
    end
    context.dependencyInputTables[value] = true
    for key, item in next, value do
        if type(key) == "table" then
            markDependencyInput(context, key, seen)
        end
        if type(item) == "table" then
            markDependencyInput(context, item, seen)
        end
    end
end

local function protectedDependencyCall(callback, arguments)
    return packValues(callback(unpack(arguments, 1, arguments.n)))
end

local function dependencyCall(context, callback, ...)
    if not dependencyBindingsMatch(context) or type(callback) ~= "function" then
        return nil
    end
    local arguments = packValues(...)
    local seenInputs = {}
    for index = 1, arguments.n do
        markDependencyInput(context, arguments[index], seenInputs)
    end
    local ok, results = pcall(protectedDependencyCall, callback, arguments)
    if not ok or type(results) ~= "table" or getmetatable(results) ~= nil
        or not dependencyBindingsMatch(context) then
        return nil
    end
    return results
end

local function exactSuccess(results)
    return results ~= nil and results.n == 1
end

local function exactFailure(results)
    return results ~= nil
        and results.n == 2
        and results[1] == nil
        and type(results[2]) == "string"
end

-- Accepted Geometry.publicCall returns its logical success plus an explicit
-- nil reason, while declarative ports return the logical success alone.
local function exactGeometrySuccess(results)
    return results ~= nil
        and (results.n == 1 or (results.n == 2 and results[2] == nil))
        and results[1] ~= nil
end

local function exactTrueArray(value, count)
    if type(value) ~= "table" or getmetatable(value) ~= nil then
        return false
    end
    local found = 0
    for key, item in next, value do
        if not finiteNumber(key) or key ~= math.floor(key)
            or key < 1 or key > count or item ~= true then
            return false
        end
        found = found + 1
    end
    return found == count
end

local probeValidation

local function independentCopy(value, context)
    local seen = {}
    local itemCount = 0

    local function copyValue(source, depth)
        itemCount = itemCount + 1
        if itemCount > context.maxNeutralItems
            or depth > context.maxNeutralDepth then
            return nil, "invalidSnapshot", false
        end

        local sourceType = type(source)
        if sourceType == "nil" or sourceType == "boolean" then
            return source, nil, true
        elseif sourceType == "number" then
            if not finiteNumber(source)
                or math.abs(source) > context.maxIdentifier then
                return nil, "invalidSnapshot", false
            end
            return source, nil, true
        elseif sourceType == "string" then
            if #source > context.maxStringBytes then
                return nil, "invalidSnapshot", false
            end
            return source, nil, true
        elseif sourceType ~= "table" then
            return nil, "invalidSnapshot", false
        end

        if getmetatable(source) ~= nil or seen[source] then
            return nil, "invalidSnapshot", false
        end
        seen[source] = true
        context.callerTables[source] = true

        local numericCount = 0
        local stringCount = 0
        local maximumIndex = 0
        local childCount = 0
        for key in next, source do
            childCount = childCount + 1
            local keyType = type(key)
            if keyType == "number" then
                if not finiteNumber(key) or key ~= math.floor(key) or key < 1 then
                    return nil, "invalidSnapshot", false
                end
                numericCount = numericCount + 1
                if key > maximumIndex then
                    maximumIndex = key
                end
            elseif keyType == "string" then
                if #key > context.maxStringBytes then
                    return nil, "invalidSnapshot", false
                end
                stringCount = stringCount + 1
            else
                return nil, "invalidSnapshot", false
            end
        end
        if numericCount > 0 and stringCount > 0 then
            return nil, "invalidSnapshot", false
        end
        if numericCount > 0 and maximumIndex ~= numericCount then
            return nil, "invalidSnapshot", false
        end
        if depth >= context.maxNeutralDepth and childCount > 0 then
            return nil, "invalidSnapshot", false
        end

        local target = {}
        context.localTables[target] = true
        if numericCount > 0 then
            for index = 1, numericCount do
                local copied, reason, ok = copyValue(rawget(source, index), depth + 1)
                if not ok then
                    return nil, reason, false
                end
                rawset(target, index, copied)
            end
        else
            for key, item in next, source do
                local copied, reason, ok = copyValue(item, depth + 1)
                if not ok then
                    return nil, reason, false
                end
                rawset(target, key, copied)
            end
        end
        return target, nil, true
    end

    return copyValue(value, 0)
end

local function neutralEqual(left, right)
    local seenLeft = {}
    local seenRight = {}

    local function equalValue(first, second, depth)
        if depth > 64 or type(first) ~= type(second) then
            return false
        end
        if type(first) ~= "table" then
            return first == second
        end
        if getmetatable(first) ~= nil or getmetatable(second) ~= nil
            or seenLeft[first] or seenRight[second] then
            return false
        end
        seenLeft[first] = true
        seenRight[second] = true
        local firstCount = 0
        for key, item in next, first do
            firstCount = firstCount + 1
            local other = rawget(second, key)
            if other == nil or not equalValue(item, other, depth + 1) then
                return false
            end
        end
        local secondCount = 0
        for _ in next, second do
            secondCount = secondCount + 1
        end
        return firstCount == secondCount
    end

    return equalValue(left, right, 0)
end

local function outputTableBlocked(context, value)
    return context.callerTables[value] == true
        or context.localTables[value] == true
        or context.dependencyTables[value] == true
        or context.dependencyInputTables[value] == true
        or context.dependencyOutputTables[value] ~= nil
end

local function registerGenericOutput(context, value)
    if type(value) ~= "table" then
        return nil
    end
    local seen = {}

    local function snapshotTable(source)
        if type(source) ~= "table" or getmetatable(source) ~= nil
            or seen[source] or outputTableBlocked(context, source) then
            return nil
        end
        seen[source] = true
        context.dependencyOutputTables[source] = true
        local node = {value = source, entries = {}}
        for key, item in next, source do
            local keyType = type(key)
            if keyType ~= "number" and keyType ~= "string" then
                return nil
            end
            local entry = {key = key, value = item}
            node.entries[#node.entries + 1] = entry
            if type(item) == "table" then
                entry.child = snapshotTable(item)
                if entry.child == nil then
                    return nil
                end
            elseif type(item) == "function" or type(item) == "thread"
                or type(item) == "userdata" then
                return nil
            end
        end
        return node
    end

    local root = snapshotTable(value)
    if root == nil then
        return nil
    end
    local record = {kind = "generic", root = root}
    context.outputRecords[#context.outputRecords + 1] = record
    return record
end

local function exactPointTable(value, x, z)
    if type(value) ~= "table" or getmetatable(value) ~= nil
        or rawget(value, "x") ~= x or rawget(value, "z") ~= z then
        return false
    end
    local count = 0
    for key in next, value do
        count = count + 1
        if key ~= "x" and key ~= "z" then
            return false
        end
    end
    return count == 2
end

local function registerPointOutput(context, value, expected, count, retain)
    if type(value) ~= "table" or getmetatable(value) ~= nil
        or outputTableBlocked(context, value) then
        return nil
    end
    local found = 0
    for key in next, value do
        found = found + 1
        if not finiteNumber(key) or key ~= math.floor(key)
            or key < 1 or key > count then
            return nil
        end
    end
    if found ~= count then
        return nil
    end

    local record = {
        kind = "points",
        count = count,
        expected = expected,
        owners = context.dependencyOutputTables,
        weakRoot = setmetatable({value = value}, {__mode = "v"}),
        weakPoints = setmetatable({}, {__mode = "v"})
    }
    if retain then
        record.strongRoot = value
    end
    context.dependencyOutputTables[value] = record
    for index = 1, count do
        local item = rawget(value, index)
        local x = rawget(expected[index], "x")
        local z = rawget(expected[index], "z")
        if type(item) ~= "table" or outputTableBlocked(context, item)
            or not exactPointTable(item, x, z) then
            return nil
        end
        context.dependencyOutputTables[item] = record
        record.weakPoints[index] = item
    end
    context.outputRecords[#context.outputRecords + 1] = record
    return record
end

local function revalidateGenericNode(node, seen)
    local value = node.value
    if type(value) ~= "table" or getmetatable(value) ~= nil or seen[value] then
        return false
    end
    seen[value] = true
    local count = 0
    for _ in next, value do
        count = count + 1
    end
    if count ~= #node.entries then
        return false
    end
    for index = 1, #node.entries do
        local entry = node.entries[index]
        if not rawequal(rawget(value, entry.key), entry.value) then
            return false
        end
        if entry.child ~= nil and not revalidateGenericNode(entry.child, seen) then
            return false
        end
    end
    return true
end

local function revalidateOutput(record)
    if record.kind == "generic" then
        return revalidateGenericNode(record.root, {})
    end
    local root = record.strongRoot or record.weakRoot.value
    if root == nil then
        for index = 1, record.count do
            local item = record.weakPoints[index]
            if item ~= nil then
                local expected = rawget(record.expected, index)
                if record.owners[item] ~= record
                    or not exactPointTable(
                        item,
                        rawget(expected, "x"),
                        rawget(expected, "z")
                    ) then
                    return false
                end
            end
        end
        return true
    end
    if type(root) ~= "table" or getmetatable(root) ~= nil
        or record.owners[root] ~= record then
        return false
    end
    local count = 0
    for key in next, root do
        count = count + 1
        if not finiteNumber(key) or key ~= math.floor(key)
            or key < 1 or key > record.count then
            return false
        end
    end
    if count ~= record.count then
        return false
    end
    for index = 1, record.count do
        local item = rawget(root, index)
        local expected = rawget(record.expected, index)
        if record.owners[item] ~= record
            or not rawequal(item, record.weakPoints[index])
            or not exactPointTable(
                item,
                rawget(expected, "x"),
                rawget(expected, "z")
            ) then
            return false
        end
    end
    return true
end

local function outputRoot(record)
    return record.strongRoot or record.weakRoot.value
end

local function revalidateAllOutputs(context)
    for index = 1, #context.outputRecords do
        if not revalidateOutput(context.outputRecords[index]) then
            return false
        end
    end
    return true
end

probeValidation = function(context)
    local validation = context.validation
    local function expected(callback, expectedValue, ...)
        local results = dependencyCall(context, callback, ...)
        return exactSuccess(results) and results[1] == expectedValue
    end

    if not expected(context.validationFunctions.isFinite, true, 0)
        or not expected(context.validationFunctions.number, 0, 0, -1, 1)
        or not expected(
            context.validationFunctions.integer,
            1,
            1,
            1,
            context.maxIdentifier
        ) then
        return nil, "dependencyContractViolation"
    end

    local allowed = {accepted = true}
    if not expected(context.validationFunctions.enum, "accepted", "accepted", allowed)
        or not exactTrueArray({rawget(allowed, "accepted")}, 1) then
        return nil, "dependencyContractViolation"
    end
    local allowedCount = 0
    for key, item in next, allowed do
        allowedCount = allowedCount + 1
        if key ~= "accepted" or item ~= true then
            return nil, "dependencyContractViolation"
        end
    end
    if allowedCount ~= 1
        or not expected(context.validationFunctions.asciiToken, "A", "A", 1)
        or not expected(context.validationFunctions.text, "", "", 0) then
        return nil, "dependencyContractViolation"
    end

    local array = {true}
    local arrayResults = dependencyCall(
        context,
        context.validationFunctions.array,
        array,
        1
    )
    if not exactSuccess(arrayResults) or not rawequal(arrayResults[1], array)
        or not exactTrueArray(array, 1) then
        return nil, "dependencyContractViolation"
    end

    local sentinel = {flag = true, nested = {1, "A"}}
    local limits = {
        maxDepth = 2,
        maxItems = 5,
        maxStringBytes = context.maxStringBytes,
        maxNumber = context.maxIdentifier
    }
    local copyResults = dependencyCall(
        context,
        context.validationFunctions.copy,
        sentinel,
        limits
    )
    if not exactSuccess(copyResults)
        or registerGenericOutput(context, copyResults[1]) == nil
        or not neutralEqual(copyResults[1], sentinel)
        or not neutralEqual(sentinel, {flag = true, nested = {1, "A"}})
        or not neutralEqual(limits, {
            maxDepth = 2,
            maxItems = 5,
            maxStringBytes = context.maxStringBytes,
            maxNumber = context.maxIdentifier
        }) then
        return nil, "dependencyContractViolation"
    end
    return true
end

local function closedMap(value, allowed)
    if type(value) ~= "table" or getmetatable(value) ~= nil then
        return false
    end
    local count = 0
    for key in next, value do
        count = count + 1
        if type(key) ~= "string" or rawget(allowed, key) ~= true then
            return false
        end
    end
    return count <= 16
end

local function localDenseArray(value, maximum, exact, minimum)
    if type(value) ~= "table" or getmetatable(value) ~= nil then
        return nil
    end
    local count = 0
    local maximumIndex = 0
    for key in next, value do
        count = count + 1
        if count > maximum or not finiteNumber(key)
            or key ~= math.floor(key) or key < 1 then
            return nil
        end
        if key > maximumIndex then
            maximumIndex = key
        end
    end
    if maximumIndex ~= count or (exact ~= nil and count ~= exact)
        or (minimum ~= nil and count < minimum) then
        return nil
    end
    return count
end

local function probeArray(context, count, maximum)
    local value = {}
    for index = 1, count do
        value[index] = true
    end
    local results = dependencyCall(
        context,
        context.validationFunctions.array,
        value,
        maximum
    )
    if not exactSuccess(results) or not rawequal(results[1], value)
        or not exactTrueArray(value, count) then
        return nil, "dependencyContractViolation"
    end
    return true
end

local function validateInteger(context, value, minimum, maximum)
    if not finiteNumber(value) or value ~= math.floor(value)
        or value < minimum or value > maximum then
        return nil, "invalidSnapshot"
    end
    local results = dependencyCall(
        context,
        context.validationFunctions.integer,
        value,
        minimum,
        maximum
    )
    if not exactSuccess(results) or results[1] ~= value then
        return nil, "dependencyContractViolation"
    end
    return value
end

local function validateNumber(context, value, minimum, maximum)
    if not finiteNumber(value) or value < minimum or value > maximum then
        return nil, "invalidSnapshot"
    end
    local results = dependencyCall(
        context,
        context.validationFunctions.number,
        value,
        minimum,
        maximum
    )
    if not exactSuccess(results) or results[1] ~= value then
        return nil, "dependencyContractViolation"
    end
    return value
end

local function validatePointShape(value, context)
    if not closedMap(value, POINT_KEYS)
        or rawget(value, "x") == nil or rawget(value, "z") == nil then
        return nil, "invalidSnapshot"
    end
    local x = rawget(value, "x")
    local z = rawget(value, "z")
    if not finiteNumber(x) or not finiteNumber(z)
        or x < -context.maxWorldCoordinate or x > context.maxWorldCoordinate
        or z < -context.maxWorldCoordinate or z > context.maxWorldCoordinate then
        return nil, "invalidSnapshot"
    end
    return true
end

local function exactPoint(value, x, z, context)
    return validatePointShape(value, context) ~= nil
        and rawget(value, "x") == x
        and rawget(value, "z") == z
end

local function validGeometryReason(reason)
    return type(reason) == "string" and #reason >= 1 and #reason <= 64
end

local function pointListMatches(value, expected, count)
    if type(value) ~= "table" or getmetatable(value) ~= nil then
        return false
    end
    local found = 0
    for key in next, value do
        found = found + 1
        if not finiteNumber(key) or key ~= math.floor(key)
            or key < 1 or key > count then
            return false
        end
    end
    if found ~= count then
        return false
    end
    for index = 1, count do
        if not exactPointTable(
            rawget(value, index),
            rawget(expected[index], "x"),
            rawget(expected[index], "z")
        ) then
            return false
        end
    end
    return true
end

local function callQuadrilateral(context, workArea, retain)
    local start = workArea.start
    local width = workArea.width
    local height = workArea.height
    local startX, startZ = start.x, start.z
    local widthX, widthZ = width.x, width.z
    local heightX, heightZ = height.x, height.z
    local results = dependencyCall(
        context,
        context.geometryFunctions.quadrilateral,
        start,
        width,
        height
    )
    if not exactPointTable(start, startX, startZ)
        or not exactPointTable(width, widthX, widthZ)
        or not exactPointTable(height, heightX, heightZ) then
        return nil, "dependencyContractViolation"
    end
    if exactFailure(results) then
        if validGeometryReason(results[2]) then
            return nil, "invalidSnapshot"
        end
        return nil, "dependencyContractViolation"
    end
    if not exactGeometrySuccess(results) then
        return nil, "dependencyContractViolation"
    end
    local quad = results[1]
    local oppositeX = width.x + height.x - start.x
    local oppositeZ = width.z + height.z - start.z
    local expected = {start, width, {x = oppositeX, z = oppositeZ}, height}
    local record = registerPointOutput(context, quad, expected, 4, retain)
    if record == nil or not pointListMatches(quad, expected, 4) then
        return nil, "dependencyContractViolation"
    end
    return record
end

local function callPolygon(context, polygon, retain)
    local results = dependencyCall(
        context,
        context.geometryFunctions.polygon,
        polygon
    )
    if exactFailure(results) then
        if validGeometryReason(results[2]) then
            return nil, "invalidSnapshot"
        end
        return nil, "dependencyContractViolation"
    end
    if not exactGeometrySuccess(results) then
        return nil, "dependencyContractViolation"
    end
    local record = registerPointOutput(
        context,
        results[1],
        polygon,
        #polygon,
        retain
    )
    if record == nil then
        return nil, "dependencyContractViolation"
    end
    return record
end

local function callClassification(context, quad, polygon)
    if not revalidateOutput(quad) or not revalidateOutput(polygon) then
        return nil, "dependencyContractViolation"
    end
    local quadRoot = outputRoot(quad)
    local polygonRoot = outputRoot(polygon)
    if quadRoot == nil or polygonRoot == nil then
        return nil, "dependencyContractViolation"
    end
    local results = dependencyCall(
        context,
        context.geometryFunctions.classifyQuadrilateral,
        quadRoot,
        polygonRoot,
        context.defaultEpsilon
    )
    if not revalidateOutput(quad) or not revalidateOutput(polygon)
        or not exactGeometrySuccess(results) then
        return nil, "dependencyContractViolation"
    end
    local relation = results[1]
    if relation ~= "inside" and relation ~= "boundary"
            and relation ~= "crossing" and relation ~= "outside" then
        return nil, "dependencyContractViolation"
    end
    return relation
end

local function validateSample(context, sample)
    if not closedMap(sample, SAMPLE_KEYS) or rawget(sample, "farmlandId") == nil then
        return nil, "invalidSnapshot"
    end
    local farmlandId, reason = validateInteger(
        context,
        rawget(sample, "farmlandId"),
        0,
        context.maxIdentifier
    )
    if farmlandId == nil then
        return nil, reason
    end
    local ownerFarmId = rawget(sample, "ownerFarmId")
    if ownerFarmId ~= nil then
        ownerFarmId, reason = validateInteger(
            context,
            ownerFarmId,
            0,
            context.maxIdentifier
        )
        if ownerFarmId == nil then
            return nil, reason
        end
    end
    local ground = rawget(sample, "isFieldGround")
    if ground ~= nil and type(ground) ~= "boolean" then
        return nil, "invalidSnapshot"
    end
    return {
        farmlandId = farmlandId,
        ownerFarmId = ownerFarmId,
        isFieldGround = ground
    }
end

local function validateSnapshot(snapshot, context)
    if not closedMap(snapshot, SNAPSHOT_KEYS)
        or rawget(snapshot, "missionWork") == nil
        or rawget(snapshot, "workArea") == nil
        or rawget(snapshot, "samples") == nil
        or rawget(snapshot, "centerSample") == nil then
        return nil, "invalidSnapshot"
    end

    local farmId = rawget(snapshot, "farmId")
    local reason
    if farmId ~= nil then
        farmId, reason = validateInteger(context, farmId, 0, context.maxIdentifier)
        if farmId == nil then
            return nil, reason
        end
    end
    local missionWork = rawget(snapshot, "missionWork")
    if type(missionWork) ~= "boolean" then
        return nil, "invalidSnapshot"
    end

    local workArea = rawget(snapshot, "workArea")
    if not closedMap(workArea, WORK_AREA_KEYS)
        or rawget(workArea, "start") == nil
        or rawget(workArea, "width") == nil
        or rawget(workArea, "height") == nil then
        return nil, "invalidSnapshot"
    end
    for _, key in next, {"start", "width", "height"} do
        local valid, pointReason = validatePointShape(rawget(workArea, key), context)
        if valid == nil then
            return nil, pointReason
        end
    end

    local samples = rawget(snapshot, "samples")
    local sampleCount = localDenseArray(samples, 4, 4, 4)
    if sampleCount == nil then
        return nil, "invalidSnapshot"
    end
    local arrayValid, arrayReason = probeArray(context, sampleCount, 4)
    if arrayValid == nil then
        return nil, arrayReason
    end
    local normalizedSamples = {}
    for index = 1, 4 do
        normalizedSamples[index], reason = validateSample(context, samples[index])
        if normalizedSamples[index] == nil then
            return nil, reason
        end
    end
    local center
    center, reason = validateSample(context, rawget(snapshot, "centerSample"))
    if center == nil then
        return nil, reason
    end

    local fieldsValue = rawget(snapshot, "fields")
    local fields = {}
    if fieldsValue ~= nil then
        local fieldCount = localDenseArray(
            fieldsValue,
            context.maxBoundaryCandidates,
            nil,
            0
        )
        if fieldCount == nil then
            return nil, "invalidSnapshot"
        end
        arrayValid, arrayReason = probeArray(
            context,
            fieldCount,
            context.maxBoundaryCandidates
        )
        if arrayValid == nil then
            return nil, arrayReason
        end
        for index = 1, fieldCount do
            local descriptor = fieldsValue[index]
            if not closedMap(descriptor, FIELD_KEYS)
                or rawget(descriptor, "fieldId") == nil
                or rawget(descriptor, "farmlandId") == nil
                or rawget(descriptor, "polygon") == nil then
                return nil, "invalidSnapshot"
            end
            local fieldId
            fieldId, reason = validateInteger(
                context,
                rawget(descriptor, "fieldId"),
                1,
                context.maxIdentifier
            )
            if fieldId == nil then
                return nil, reason
            end
            local farmlandId
            farmlandId, reason = validateInteger(
                context,
                rawget(descriptor, "farmlandId"),
                1,
                context.maxIdentifier
            )
            if farmlandId == nil then
                return nil, reason
            end
            local areaHa = rawget(descriptor, "areaHa")
            if areaHa ~= nil then
                areaHa, reason = validateNumber(context, areaHa, 0, context.maxAreaHa)
                if areaHa == nil then
                    return nil, reason
                end
                if areaHa <= 0 then
                    return nil, "invalidSnapshot"
                end
            end
            local polygon = rawget(descriptor, "polygon")
            local polygonCount = localDenseArray(
                polygon,
                context.maxPolygonPoints,
                nil,
                3
            )
            if polygonCount == nil then
                return nil, "invalidSnapshot"
            end
            arrayValid, arrayReason = probeArray(
                context,
                polygonCount,
                context.maxPolygonPoints
            )
            if arrayValid == nil then
                return nil, arrayReason
            end
            for pointIndex = 1, polygonCount do
                local valid, pointReason = validatePointShape(
                    polygon[pointIndex],
                    context
                )
                if valid == nil then
                    return nil, pointReason
                end
            end
            fields[index] = {
                fieldId = fieldId,
                farmlandId = farmlandId,
                areaHa = areaHa,
                polygon = polygon
            }
        end
    end

    local classificationRequired = {}
    local sampledLand = {}
    local sampledLandCount = 0
    local canClassify = farmId ~= nil and farmId ~= 0 and not missionWork
    normalizedSamples[5] = center
    for index = 1, 5 do
        local row = normalizedSamples[index]
        if row.farmlandId == 0 or row.ownerFarmId == nil
            or row.ownerFarmId == 0 or row.ownerFarmId ~= farmId then
            canClassify = false
        elseif not sampledLand[row.farmlandId] then
            sampledLand[row.farmlandId] = true
            sampledLandCount = sampledLandCount + 1
        end
    end
    if canClassify then
        for index = 1, #fields do
            if not sampledLand[fields[index].farmlandId] then
                canClassify = false
                break
            end
        end
    end
    if canClassify then
        if sampledLandCount == 1 and #fields == 1 then
            classificationRequired[1] = true
        elseif sampledLandCount > 1 then
            for index = 1, #fields do
                classificationRequired[index] = true
            end
        end
    end

    local quad
    quad, reason = callQuadrilateral(
        context,
        workArea,
        next(classificationRequired) ~= nil
    )
    if quad == nil then
        return nil, reason
    end
    for index = 1, #fields do
        fields[index].normalizedPolygon, reason = callPolygon(
            context,
            fields[index].polygon,
            classificationRequired[index] == true
        )
        if fields[index].normalizedPolygon == nil then
            return nil, reason
        end
    end

    return {
        farmId = farmId,
        missionWork = missionWork,
        samples = normalizedSamples,
        fields = fields,
        quad = quad
    }
end

local function canonicalLandKey(context, farmId, farmlandId, fieldId)
    local farmText = string.format("%.0f", farmId)
    local farmlandText = string.format("%.0f", farmlandId)
    local fieldPart = fieldId == nil
        and "parcel"
        or "base-" .. string.format("%.0f", fieldId)
    local literal = "farm:" .. farmText
        .. "/farmland:" .. farmlandText
        .. "/field:" .. fieldPart

    local results = dependencyCall(
        context,
        context.identifierLandKey,
        farmId,
        farmlandId,
        fieldId
    )
    if exactFailure(results) then
        if results[2] == "stringTooLong" then
            return nil, "invalidSnapshot"
        end
        return nil, "dependencyContractViolation"
    end
    if not exactSuccess(results) then
        return nil, "dependencyContractViolation"
    end
    local key = results[1]
    if type(key) ~= "string" or #key < 1 or #key > context.idBytes then
        return nil, "dependencyContractViolation"
    end
    for index = 1, #key do
        local byte = string.byte(key, index)
        if byte < 33 or byte > 126 then
            return nil, "dependencyContractViolation"
        end
    end

    results = dependencyCall(
        context,
        context.validationFunctions.asciiToken,
        key,
        context.idBytes
    )
    if not exactSuccess(results) or results[1] ~= key then
        return nil, "dependencyContractViolation"
    end

    results = dependencyCall(
        context,
        context.identifierParseLandKey,
        key
    )
    if not exactSuccess(results) or type(results[1]) ~= "table"
        or registerGenericOutput(context, results[1]) == nil then
        return nil, "dependencyContractViolation"
    end
    local parts = results[1]
    local allowed = fieldId == nil
        and {farmId = true, farmlandId = true, fieldKind = true, fieldPart = true}
        or {farmId = true, farmlandId = true, fieldId = true,
            fieldKind = true, fieldPart = true}
    if not closedMap(parts, allowed)
        or rawget(parts, "farmId") ~= farmId
        or rawget(parts, "farmlandId") ~= farmlandId then
        return nil, "dependencyContractViolation"
    end
    if fieldId == nil then
        if rawget(parts, "fieldId") ~= nil
            or rawget(parts, "fieldKind") ~= "parcel"
            or rawget(parts, "fieldPart") ~= "parcel" then
            return nil, "dependencyContractViolation"
        end
    elseif rawget(parts, "fieldId") ~= fieldId
        or rawget(parts, "fieldKind") ~= "base"
        or rawget(parts, "fieldPart") ~= fieldPart then
        return nil, "dependencyContractViolation"
    end
    if key ~= literal then
        return nil, "dependencyContractViolation"
    end
    return key
end

local function candidateResult(context, farmId, candidates)
    local unique = {}
    local result = {}
    for index = 1, #candidates do
        local key = candidates[index]
        if not unique[key] then
            unique[key] = true
            result[#result + 1] = key
        end
    end
    table.sort(result, unsignedByteLess)
    if #result > context.maxBoundaryCandidates then
        return nil, "tooManyBoundaryCandidates"
    end
    if #result < 2 then
        return nil, "dependencyContractViolation"
    end
    return {
        kind = "mixed",
        landKey = result[1],
        farmId = farmId,
        candidateLandKeys = result,
        qualityClass = context.partial,
        reasons = {"boundaryUnresolved"}
    }
end

local function parcelResult(context, farmId, farmlandId, key, custom)
    return {
        kind = "parcel",
        landKey = key,
        farmId = farmId,
        farmlandId = farmlandId,
        fieldKind = "parcel",
        qualityClass = context.partial,
        reasons = custom
            and {"customFieldGeometry", "parcelFallback"}
            or {"parcelFallback"}
    }
end

local function baseResult(context, farmId, descriptor, key)
    local result = {
        kind = "baseField",
        landKey = key,
        farmId = farmId,
        farmlandId = descriptor.farmlandId,
        fieldId = descriptor.fieldId,
        fieldKind = "base",
        qualityClass = context.complete,
        reasons = {}
    }
    if descriptor.areaHa ~= nil then
        result.cycleAreaHa = descriptor.areaHa
    end
    return result
end

local function allGroundTrue(samples)
    for index = 1, 5 do
        if samples[index].isFieldGround ~= true then
            return false
        end
    end
    return true
end

local function descriptorIdentityLess(left, right)
    if left.farmlandId ~= right.farmlandId then
        return left.farmlandId < right.farmlandId
    end
    if left.fieldId ~= right.fieldId then
        return left.fieldId < right.fieldId
    end
    return left.sourceIndex < right.sourceIndex
end

local function resolveValidated(value, context)
    local farmId = value.farmId
    if farmId == nil or farmId == 0 then
        return nil, "missingActiveFarm"
    end
    if value.missionWork then
        return nil, "missionWork"
    end

    local hasNoLand = false
    local hasNoOwner = false
    local hasForeignOwner = false
    local farmlandSet = {}
    local farmlands = {}
    for index = 1, 5 do
        local sample = value.samples[index]
        if sample.farmlandId == 0 then
            hasNoLand = true
        elseif not farmlandSet[sample.farmlandId] then
            farmlandSet[sample.farmlandId] = true
            farmlands[#farmlands + 1] = sample.farmlandId
        end
        if sample.ownerFarmId == nil or sample.ownerFarmId == 0 then
            hasNoOwner = true
        elseif sample.ownerFarmId ~= farmId then
            hasForeignOwner = true
        end
    end
    if hasNoLand then
        return nil, "noLand"
    elseif hasNoOwner then
        return nil, "noOwner"
    elseif hasForeignOwner then
        return nil, "foreignOwner"
    end
    table.sort(farmlands)

    local descriptors = {}
    local descriptorsByFarmland = {}
    for index = 1, #value.fields do
        local descriptor = value.fields[index]
        if not farmlandSet[descriptor.farmlandId] then
            return nil, "fieldMappingMismatch"
        end
        descriptor.sourceIndex = index
        descriptors[#descriptors + 1] = descriptor
        local group = descriptorsByFarmland[descriptor.farmlandId]
        if group == nil then
            group = {}
            descriptorsByFarmland[descriptor.farmlandId] = group
        end
        group[#group + 1] = descriptor
    end
    table.sort(descriptors, descriptorIdentityLess)

    if #farmlands == 1 then
        local farmlandId = farmlands[1]
        local group = descriptorsByFarmland[farmlandId] or {}
        if #group == 0 then
            if not allGroundTrue(value.samples) then
                return nil, "fieldGroundUnproven"
            end
            local parcelKey, keyReason = canonicalLandKey(
                context,
                farmId,
                farmlandId,
                nil
            )
            if parcelKey == nil then
                return nil, keyReason
            end
            return parcelResult(context, farmId, farmlandId, parcelKey, false)
        elseif #group == 1 then
            local descriptor = group[1]
            local baseKey, keyReason = canonicalLandKey(
                context,
                farmId,
                farmlandId,
                descriptor.fieldId
            )
            if baseKey == nil then
                return nil, keyReason
            end
            local relation
            relation, keyReason = callClassification(
                context,
                value.quad,
                descriptor.normalizedPolygon
            )
            if relation == nil then
                return nil, keyReason
            end
            if relation == "inside" then
                return baseResult(context, farmId, descriptor, baseKey)
            end
            local parcelKey
            parcelKey, keyReason = canonicalLandKey(
                context,
                farmId,
                farmlandId,
                nil
            )
            if parcelKey == nil then
                return nil, keyReason
            end
            if relation == "outside" then
                if not allGroundTrue(value.samples) then
                    return nil, "fieldGroundUnproven"
                end
                return parcelResult(context, farmId, farmlandId, parcelKey, true)
            end
            return candidateResult(context, farmId, {baseKey, parcelKey})
        end

        local candidates = {}
        local parcelKey, keyReason = canonicalLandKey(
            context,
            farmId,
            farmlandId,
            nil
        )
        if parcelKey == nil then
            return nil, keyReason
        end
        candidates[#candidates + 1] = parcelKey
        local previousFieldId = nil
        for index = 1, #descriptors do
            local descriptor = descriptors[index]
            if descriptor.fieldId ~= previousFieldId then
                local baseKey
                baseKey, keyReason = canonicalLandKey(
                    context,
                    farmId,
                    farmlandId,
                    descriptor.fieldId
                )
                if baseKey == nil then
                    return nil, keyReason
                end
                candidates[#candidates + 1] = baseKey
                previousFieldId = descriptor.fieldId
            end
        end
        return candidateResult(context, farmId, candidates)
    end

    local candidates = {}
    local parcelKeys = {}
    local keyReason
    for index = 1, #farmlands do
        local farmlandId = farmlands[index]
        parcelKeys[farmlandId], keyReason = canonicalLandKey(
            context,
            farmId,
            farmlandId,
            nil
        )
        if parcelKeys[farmlandId] == nil then
            return nil, keyReason
        end
        candidates[#candidates + 1] = parcelKeys[farmlandId]
    end

    local baseKeyByIdentity = {}
    for index = 1, #descriptors do
        local descriptor = descriptors[index]
        local identity = string.format("%.0f:%.0f", descriptor.farmlandId,
            descriptor.fieldId)
        if baseKeyByIdentity[identity] == nil then
            baseKeyByIdentity[identity], keyReason = canonicalLandKey(
                context,
                farmId,
                descriptor.farmlandId,
                descriptor.fieldId
            )
            if baseKeyByIdentity[identity] == nil then
                return nil, keyReason
            end
        end
    end

    local includedBase = {}
    for index = 1, #descriptors do
        local descriptor = descriptors[index]
        local identity = string.format("%.0f:%.0f", descriptor.farmlandId,
            descriptor.fieldId)
        local relation
        relation, keyReason = callClassification(
            context,
            value.quad,
            descriptor.normalizedPolygon
        )
        if relation == nil then
            return nil, keyReason
        end
        if relation ~= "outside" and not includedBase[identity] then
            includedBase[identity] = true
            candidates[#candidates + 1] = baseKeyByIdentity[identity]
        end
    end
    return candidateResult(context, farmId, candidates)
end

local function resolveInternal(snapshot)
    local context, dependencyReason = resolveDependencies()
    if context == nil then
        return nil, dependencyReason
    end
    local copied, copyReason, copyOk = independentCopy(snapshot, context)
    local function checked(first, second)
        if not dependencyGraphMatches(context)
            or not revalidateAllOutputs(context)
            or (copyOk and not neutralEqual(snapshot, copied)) then
            return nil, "dependencyContractViolation"
        end
        return first, second
    end
    if not copyOk or type(copied) ~= "table" then
        return checked(nil, copyReason or "invalidSnapshot")
    end

    local probed, probeReason = probeValidation(context)
    if probed == nil then
        return checked(nil, probeReason)
    end

    local validated, validationReason = validateSnapshot(copied, context)
    if validated == nil then
        return checked(nil, validationReason)
    end
    local result, reason = resolveValidated(validated, context)
    return checked(result, reason)
end

local function protectedResolve(arguments)
    return packValues(resolveInternal(unpack(arguments, 1, arguments.n)))
end

function FieldAttribution.resolve(...)
    local arguments = packValues(...)
    if arguments.n ~= 1 then
        return nil, "invalidSnapshot"
    end
    local ok, results = pcall(protectedResolve, arguments)
    if not ok or type(results) ~= "table" or results.n ~= 2 then
        return nil, "dependencyContractViolation"
    end
    return results[1], results[2]
end

FieldProfitabilityLedger.Core.FieldAttribution = FieldAttribution

return FieldAttribution
