-- Detached, bounded two-dimensional geometry for field attribution.
-- This module has no Farming Simulator runtime dependency.

FieldProfitabilityLedger = FieldProfitabilityLedger or {}
FieldProfitabilityLedger.Core = FieldProfitabilityLedger.Core or {}

local Geometry = {}

local HARD_MAX_WORLD_COORDINATE = 1000000
local HARD_MAX_POLYGON_POINTS = 4096
local HARD_MAX_GEOMETRY_EPSILON = 1

local function finiteNumber(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

local function canonicalZero(value)
    if value == 0 then
        return 0
    end
    return value
end

local function currentCore()
    if type(FieldProfitabilityLedger) ~= "table"
        or getmetatable(FieldProfitabilityLedger) ~= nil then
        return nil
    end

    local core = rawget(FieldProfitabilityLedger, "Core")
    if type(core) ~= "table" or getmetatable(core) ~= nil then
        return nil
    end
    return core
end

local function policyInteger(value, minimum, maximum)
    if not finiteNumber(value) or value ~= math.floor(value)
        or value < minimum or value > maximum then
        return nil
    end
    return value
end

local function policyNumber(value, minimum, maximum)
    if not finiteNumber(value) or value < minimum or value > maximum then
        return nil
    end
    return value
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
    return snapshot, count
end

local function plainTableMatchesSnapshot(value, snapshot, expectedCount)
    if type(value) ~= "table" or getmetatable(value) ~= nil then
        return false
    end
    local count = 0
    for key, item in next, value do
        count = count + 1
        if not rawequal(rawget(snapshot, key), item) then
            return false
        end
    end
    return count == expectedCount
end

local function dependencyStateReason(policy, validation)
    local core = currentCore()
    if core == nil or not rawequal(core, policy.dependencyCore)
        or not rawequal(rawget(core, "Constants"), policy.dependencyConstants)
        then
        return "constantsUnavailable"
    end

    local constants = policy.dependencyConstants
    local limits = policy.dependencyLimits
    if type(constants) ~= "table" or getmetatable(constants) ~= nil
        or type(limits) ~= "table" or getmetatable(limits) ~= nil
        or not rawequal(rawget(constants, "LIMITS"), limits)
        or not rawequal(
            rawget(constants, "DEFAULT_EPSILON"),
            policy.dependencyDefaultEpsilon
        )
        or not rawequal(
            rawget(limits, "maxWorldCoordinate"),
            policy.maxWorldCoordinate
        )
        or not rawequal(
            rawget(limits, "maxPolygonPoints"),
            policy.maxPolygonPoints
        )
        or not rawequal(
            rawget(limits, "maxGeometryEpsilon"),
            policy.maxGeometryEpsilon
        ) then
        return "constantsUnavailable"
    end

    if not rawequal(rawget(core, "Validation"), validation)
        or not rawequal(validation, policy.dependencyValidation)
        or not plainTableMatchesSnapshot(
            validation,
            policy.validationSnapshot,
            policy.validationItemCount
        )
        or not rawequal(
            rawget(validation, "isFinite"),
            policy.validationIsFinite
        )
        or not rawequal(
            rawget(validation, "number"),
            policy.validationNumber
        )
        or not rawequal(
            rawget(validation, "array"),
            policy.validationArray
        ) then
        return "validationUnavailable"
    end
    return nil
end

local function plainTrueArray(value, expectedCount)
    if type(value) ~= "table" or getmetatable(value) ~= nil then
        return false
    end
    local count = 0
    for key, item in next, value do
        count = count + 1
        if not finiteNumber(key) or key ~= math.floor(key) or key < 1
            or key > expectedCount or item ~= true then
            return false
        end
    end
    return count == expectedCount
end

local function probeValidation(policy, validation)
    local stateReason = dependencyStateReason(policy, validation)
    if stateReason ~= nil then
        return nil, stateReason
    end

    local isFinite = policy.validationIsFinite
    local number = policy.validationNumber
    local array = policy.validationArray
    if type(isFinite) ~= "function" or type(number) ~= "function"
        or type(array) ~= "function" then
        return nil, "validationUnavailable"
    end

    local okFinite, finiteResult, finiteExtra = pcall(isFinite, 0)
    stateReason = dependencyStateReason(policy, validation)
    if not okFinite or finiteResult ~= true
        or finiteExtra ~= nil or stateReason ~= nil then
        return nil, stateReason or "validationUnavailable"
    end
    local okInfinite, infiniteResult, infiniteExtra = pcall(
        isFinite,
        math.huge
    )
    stateReason = dependencyStateReason(policy, validation)
    if not okInfinite or infiniteResult ~= false
        or infiniteExtra ~= nil or stateReason ~= nil then
        return nil, stateReason or "validationUnavailable"
    end
    local okNumber, numberResult, numberExtra = pcall(number, 0, -1, 1)
    stateReason = dependencyStateReason(policy, validation)
    if not okNumber or numberResult ~= 0
        or numberExtra ~= nil or stateReason ~= nil then
        return nil, stateReason or "validationUnavailable"
    end
    local probe = {true}
    local okArray, arrayResult, arrayExtra = pcall(array, probe, 1)
    stateReason = dependencyStateReason(policy, validation)
    if not okArray or not rawequal(arrayResult, probe)
        or arrayExtra ~= nil or not plainTrueArray(probe, 1)
        or stateReason ~= nil then
        return nil, stateReason or "validationUnavailable"
    end

    return validation
end

local function resolvePolicy(registerGuard)
    local core = currentCore()
    if core == nil then
        return nil, nil, "constantsUnavailable"
    end

    local constants = rawget(core, "Constants")
    if type(constants) ~= "table" or getmetatable(constants) ~= nil then
        return nil, nil, "constantsUnavailable"
    end

    local limits = rawget(constants, "LIMITS")
    if type(limits) ~= "table" or getmetatable(limits) ~= nil then
        return nil, nil, "constantsUnavailable"
    end

    local maxWorldCoordinate = policyInteger(
        rawget(limits, "maxWorldCoordinate"),
        1,
        HARD_MAX_WORLD_COORDINATE
    )
    local maxPolygonPoints = policyInteger(
        rawget(limits, "maxPolygonPoints"),
        3,
        HARD_MAX_POLYGON_POINTS
    )
    local maxGeometryEpsilon = policyNumber(
        rawget(limits, "maxGeometryEpsilon"),
        0,
        HARD_MAX_GEOMETRY_EPSILON
    )
    local defaultEpsilon = policyNumber(
        rawget(constants, "DEFAULT_EPSILON"),
        0,
        maxGeometryEpsilon or -1
    )
    if maxWorldCoordinate == nil or maxPolygonPoints == nil
        or maxGeometryEpsilon == nil or defaultEpsilon == nil then
        return nil, nil, "constantsUnavailable"
    end

    local validationSource = rawget(core, "Validation")
    local validationSnapshot, validationItemCount = snapshotPlainTable(
        validationSource
    )
    if validationSnapshot == nil then
        return nil, nil, "validationUnavailable"
    end

    local policy = {
        maxWorldCoordinate = maxWorldCoordinate,
        maxPolygonPoints = maxPolygonPoints,
        maxGeometryEpsilon = maxGeometryEpsilon,
        dependencyCore = core,
        dependencyConstants = constants,
        dependencyLimits = limits,
        dependencyDefaultEpsilon = defaultEpsilon,
        dependencyValidation = validationSource,
        validationSnapshot = validationSnapshot,
        validationItemCount = validationItemCount,
        validationIsFinite = rawget(validationSource, "isFinite"),
        validationNumber = rawget(validationSource, "number"),
        validationArray = rawget(validationSource, "array")
    }
    local validation, validationReason = probeValidation(
        policy,
        validationSource
    )
    if validation == nil then
        return nil, nil, validationReason
    end

    registerGuard(policy, validation)
    return policy, validation
end

local function dependencyNumber(policy, validation, value, minimum, maximum)
    local ok, accepted, extra = pcall(
        policy.validationNumber,
        value,
        minimum,
        maximum
    )
    if not ok or accepted ~= value or extra ~= nil then
        return nil, "validationUnavailable"
    end
    return accepted
end

local function dependencyArrayShape(
    policy,
    validation,
    itemCount,
    maximumItems
)
    local value = {}
    for index = 1, itemCount do
        value[index] = true
    end
    local ok, accepted, extra = pcall(
        policy.validationArray,
        value,
        maximumItems
    )
    if not ok or not rawequal(accepted, value)
        or extra ~= nil or not plainTrueArray(value, itemCount) then
        return nil, "validationUnavailable"
    end
    return true
end

local function validateEpsilon(policy, validation, value)
    if not finiteNumber(value)
        or value < 0 or value > policy.maxGeometryEpsilon then
        return nil, "invalidEpsilon"
    end

    local accepted, reason = dependencyNumber(
        policy,
        validation,
        value,
        0,
        policy.maxGeometryEpsilon
    )
    if accepted == nil then
        return nil, reason
    end
    return canonicalZero(accepted)
end

local function pointShape(value)
    if type(value) ~= "table" or getmetatable(value) ~= nil then
        return nil, "invalidPoint"
    end

    local count = 0
    local hasX = false
    local hasZ = false
    for key in next, value do
        count = count + 1
        if key == "x" then
            hasX = true
        elseif key == "z" then
            hasZ = true
        else
            return nil, "invalidPoint"
        end
    end
    if count ~= 2 or not hasX or not hasZ then
        return nil, "invalidPoint"
    end
    return true
end

local function normalizePoint(policy, validation, value)
    local validShape, shapeReason = pointShape(value)
    if validShape == nil then
        return nil, shapeReason
    end

    local x = rawget(value, "x")
    local z = rawget(value, "z")
    if not finiteNumber(x) or not finiteNumber(z) then
        return nil, "invalidCoordinate"
    end
    if x < -policy.maxWorldCoordinate or x > policy.maxWorldCoordinate
        or z < -policy.maxWorldCoordinate or z > policy.maxWorldCoordinate then
        return nil, "coordinateOutOfRange"
    end

    local acceptedX, xReason = dependencyNumber(
        policy,
        validation,
        x,
        -policy.maxWorldCoordinate,
        policy.maxWorldCoordinate
    )
    if acceptedX == nil then
        return nil, xReason
    end
    local acceptedZ, zReason = dependencyNumber(
        policy,
        validation,
        z,
        -policy.maxWorldCoordinate,
        policy.maxWorldCoordinate
    )
    if acceptedZ == nil then
        return nil, zReason
    end

    return {
        x = canonicalZero(acceptedX),
        z = canonicalZero(acceptedZ)
    }
end

local function denseArrayShape(value, maximumItems, minimumItems, exactItems)
    if type(value) ~= "table" or getmetatable(value) ~= nil then
        return nil, "invalidArray"
    end

    local count = 0
    local maximumIndex = 0
    local hasInvalidIndex = false
    for key in next, value do
        count = count + 1
        if count > maximumItems then
            return nil, "tooManyItems"
        end
        if not finiteNumber(key) or key ~= math.floor(key) or key < 1 then
            hasInvalidIndex = true
        elseif key > maximumIndex then
            maximumIndex = key
        end
    end
    if hasInvalidIndex then
        return nil, "invalidArray"
    end
    if maximumIndex ~= count then
        return nil, "sparseArray"
    end
    if exactItems ~= nil and count ~= exactItems then
        return nil, "wrongItemCount"
    end
    if count < minimumItems then
        return nil, "tooFewItems"
    end
    return count
end

local function samePoint(left, right)
    return left.x == right.x and left.z == right.z
end

local function crossProduct(a, b, point)
    local abX = b.x - a.x
    local abZ = b.z - a.z
    local apX = point.x - a.x
    local apZ = point.z - a.z
    local cross = abX * apZ - abZ * apX
    if not finiteNumber(abX) or not finiteNumber(abZ)
        or not finiteNumber(apX) or not finiteNumber(apZ)
        or not finiteNumber(cross) then
        return nil, "nonFiniteGeometry"
    end
    return cross, abX, abZ
end

local function orientation(a, b, point, epsilon)
    local cross, abX, abZ = crossProduct(a, b, point)
    if cross == nil then
        return nil, abX
    end

    local lengthSquared = abX * abX + abZ * abZ
    if not finiteNumber(lengthSquared) then
        return nil, "nonFiniteGeometry"
    end
    local length = math.sqrt(lengthSquared)
    local tolerance = epsilon * length
    if not finiteNumber(length) or not finiteNumber(tolerance) then
        return nil, "nonFiniteGeometry"
    end

    if math.abs(cross) <= tolerance then
        return 0
    end
    if cross < 0 then
        return -1
    end
    return 1
end

local function pointOnSegment(point, a, b, epsilon)
    local sign, reason = orientation(a, b, point, epsilon)
    if sign == nil then
        return nil, reason
    end
    if sign ~= 0 then
        return false
    end

    local minX = math.min(a.x, b.x) - epsilon
    local maxX = math.max(a.x, b.x) + epsilon
    local minZ = math.min(a.z, b.z) - epsilon
    local maxZ = math.max(a.z, b.z) + epsilon
    if not finiteNumber(minX) or not finiteNumber(maxX)
        or not finiteNumber(minZ) or not finiteNumber(maxZ) then
        return nil, "nonFiniteGeometry"
    end
    return point.x >= minX and point.x <= maxX
        and point.z >= minZ and point.z <= maxZ
end

local function projectedIntervalRelation(a, b, c, d, epsilon)
    local minAllX = math.min(a.x, b.x, c.x, d.x)
    local maxAllX = math.max(a.x, b.x, c.x, d.x)
    local minAllZ = math.min(a.z, b.z, c.z, d.z)
    local maxAllZ = math.max(a.z, b.z, c.z, d.z)
    local rangeX = maxAllX - minAllX
    local rangeZ = maxAllZ - minAllZ
    if not finiteNumber(rangeX) or not finiteNumber(rangeZ) then
        return nil, "nonFiniteGeometry"
    end

    local aValue
    local bValue
    local cValue
    local dValue
    if rangeX >= rangeZ then
        aValue, bValue, cValue, dValue = a.x, b.x, c.x, d.x
    else
        aValue, bValue, cValue, dValue = a.z, b.z, c.z, d.z
    end

    local overlapStart = math.max(
        math.min(aValue, bValue),
        math.min(cValue, dValue)
    )
    local overlapEnd = math.min(
        math.max(aValue, bValue),
        math.max(cValue, dValue)
    )
    local overlapLength = overlapEnd - overlapStart
    if not finiteNumber(overlapLength) then
        return nil, "nonFiniteGeometry"
    end
    if overlapLength < -epsilon then
        return "disjoint"
    end
    if overlapLength <= epsilon then
        return "touch"
    end
    return "overlap"
end

local function segmentBoundsDisjoint(a, b, c, d, epsilon)
    local firstMinX = math.min(a.x, b.x)
    local firstMaxX = math.max(a.x, b.x)
    local firstMinZ = math.min(a.z, b.z)
    local firstMaxZ = math.max(a.z, b.z)
    local secondMinX = math.min(c.x, d.x)
    local secondMaxX = math.max(c.x, d.x)
    local secondMinZ = math.min(c.z, d.z)
    local secondMaxZ = math.max(c.z, d.z)
    return firstMaxX < secondMinX - epsilon
        or secondMaxX < firstMinX - epsilon
        or firstMaxZ < secondMinZ - epsilon
        or secondMaxZ < firstMinZ - epsilon
end

local function segmentRelationInternal(a, b, c, d, epsilon)
    if samePoint(a, b) or samePoint(c, d) then
        return nil, "degenerateSegment"
    end
    if segmentBoundsDisjoint(a, b, c, d, epsilon) then
        return "disjoint"
    end

    local first, firstReason = orientation(a, b, c, epsilon)
    if first == nil then
        return nil, firstReason
    end
    local second, secondReason = orientation(a, b, d, epsilon)
    if second == nil then
        return nil, secondReason
    end
    local third, thirdReason = orientation(c, d, a, epsilon)
    if third == nil then
        return nil, thirdReason
    end
    local fourth, fourthReason = orientation(c, d, b, epsilon)
    if fourth == nil then
        return nil, fourthReason
    end

    if first == 0 and second == 0 and third == 0 and fourth == 0 then
        return projectedIntervalRelation(a, b, c, d, epsilon)
    end

    local cOnFirst, cReason = pointOnSegment(c, a, b, epsilon)
    if cOnFirst == nil then
        return nil, cReason
    end
    local dOnFirst, dReason = pointOnSegment(d, a, b, epsilon)
    if dOnFirst == nil then
        return nil, dReason
    end
    local aOnSecond, aReason = pointOnSegment(a, c, d, epsilon)
    if aOnSecond == nil then
        return nil, aReason
    end
    local bOnSecond, bReason = pointOnSegment(b, c, d, epsilon)
    if bOnSecond == nil then
        return nil, bReason
    end
    if cOnFirst or dOnFirst or aOnSecond or bOnSecond then
        return "touch"
    end

    local firstOpposed = (first < 0 and second > 0)
        or (first > 0 and second < 0)
    local secondOpposed = (third < 0 and fourth > 0)
        or (third > 0 and fourth < 0)
    if firstOpposed and secondOpposed then
        return "cross"
    end
    return "disjoint"
end

local function exactSimplicityEdgeRelation(points, firstEdge, secondEdge)
    local a = points[firstEdge.index]
    local b = points[firstEdge.following]
    local c = points[secondEdge.index]
    local d = points[secondEdge.following]
    -- Polygon simplicity always uses exact epsilon zero. Most broad-phase
    -- candidates are separated parallel or near-parallel edges, so reject a
    -- strict same-side pair before computing lengths or repeating
    -- orientations. Normalized coordinates are bounded to +/-1,000,000, so
    -- these exact-zero cross intermediates are provably finite. Cached deltas
    -- retain the crossProduct arithmetic order. The caller has already proved
    -- exact X/Z bound overlap; any zero or potentially intersecting case falls
    -- through to the unchanged full segment oracle.
    local first = firstEdge.deltaX * (c.z - a.z)
        - firstEdge.deltaZ * (c.x - a.x)
    local second = firstEdge.deltaX * (d.z - a.z)
        - firstEdge.deltaZ * (d.x - a.x)
    if (first < 0 and second < 0) or (first > 0 and second > 0) then
        return "disjoint"
    end

    local third = secondEdge.deltaX * (a.z - c.z)
        - secondEdge.deltaZ * (a.x - c.x)
    local fourth = secondEdge.deltaX * (b.z - c.z)
        - secondEdge.deltaZ * (b.x - c.x)
    if (third < 0 and fourth < 0) or (third > 0 and fourth > 0) then
        return "disjoint"
    end
    return segmentRelationInternal(a, b, c, d, 0)
end

local function polygonAreaTwice(points)
    local total = 0
    local count = #points
    for index = 1, count do
        local following = index == count and 1 or index + 1
        local term = points[index].x * points[following].z
            - points[following].x * points[index].z
        if not finiteNumber(term) then
            return nil, "nonFiniteGeometry"
        end
        total = total + term
        if not finiteNumber(total) then
            return nil, "nonFiniteGeometry"
        end
    end
    return total
end

local function edgeBoundsLessX(left, right)
    if left.minX ~= right.minX then
        return left.minX < right.minX
    elseif left.maxX ~= right.maxX then
        return left.maxX < right.maxX
    elseif left.minZ ~= right.minZ then
        return left.minZ < right.minZ
    elseif left.maxZ ~= right.maxZ then
        return left.maxZ < right.maxZ
    end
    return left.index < right.index
end

local function edgeBoundsLessZ(left, right)
    if left.minZ ~= right.minZ then
        return left.minZ < right.minZ
    elseif left.maxZ ~= right.maxZ then
        return left.maxZ < right.maxZ
    elseif left.minX ~= right.minX then
        return left.minX < right.minX
    elseif left.maxX ~= right.maxX then
        return left.maxX < right.maxX
    end
    return left.index < right.index
end

local function edgeBoundsLessProjection(left, right)
    if left.minProjection ~= right.minProjection then
        return left.minProjection < right.minProjection
    elseif left.maxProjection ~= right.maxProjection then
        return left.maxProjection < right.maxProjection
    elseif left.minX ~= right.minX then
        return left.minX < right.minX
    elseif left.maxX ~= right.maxX then
        return left.maxX < right.maxX
    elseif left.minZ ~= right.minZ then
        return left.minZ < right.minZ
    elseif left.maxZ ~= right.maxZ then
        return left.maxZ < right.maxZ
    end
    return left.index < right.index
end

local function sortedIntervalOverlapPairCount(minimums, maximums)
    local count = #minimums
    table.sort(minimums)
    table.sort(maximums)

    -- Each strictly separated pair is counted once when the later interval's
    -- minimum event is visited. Equality remains overlap so exact touches stay
    -- candidates. The result predicts active-list comparisons on this axis.
    local endedCount = 0
    local disjointPairCount = 0
    for index = 1, count do
        local minimum = minimums[index]
        while endedCount < count
            and maximums[endedCount + 1] < minimum do
            endedCount = endedCount + 1
        end
        disjointPairCount = disjointPairCount + endedCount
    end
    return count * (count - 1) / 2 - disjointPairCount
end

local function intervalOverlapPairCount(edges, minimumKey, maximumKey)
    local count = #edges
    local minimums = {}
    local maximums = {}
    for index = 1, count do
        minimums[index] = edges[index][minimumKey]
        maximums[index] = edges[index][maximumKey]
    end
    return sortedIntervalOverlapPairCount(minimums, maximums)
end

local PROJECTION_ROUNDING_FACTOR = 1.4210854715202004e-14
local DERIVED_AXIS_LIMIT = 4
local AXIS_EQUIVALENCE_TOLERANCE = 1e-12

local function projectedPointBounds(point, axisX, axisZ)
    local productX = point.x * axisX
    local productZ = point.z * axisZ
    local value = productX + productZ
    if not finiteNumber(productX) or not finiteNumber(productZ)
        or not finiteNumber(value) then
        return nil, "nonFiniteGeometry"
    end

    -- The axis coefficients are fixed binary64 values, so a true segment
    -- intersection still has one exact real projection on that axis. Expand
    -- each evaluated dot product far beyond its multiply/add rounding error;
    -- this may retain extra pairs but cannot make a real overlap disappear.
    local rounding = PROJECTION_ROUNDING_FACTOR * (
        math.abs(productX) + math.abs(productZ) + math.abs(value) + 1
    )
    local minimum = value - rounding
    local maximum = value + rounding
    if not finiteNumber(rounding) or not finiteNumber(minimum)
        or not finiteNumber(maximum) then
        return nil, "nonFiniteGeometry"
    end
    return minimum, maximum
end

local function projectedEdgeBounds(points, edge, axisX, axisZ)
    local firstMinimum, firstMaximum = projectedPointBounds(
        points[edge.index],
        axisX,
        axisZ
    )
    if firstMinimum == nil then
        return nil, firstMaximum
    end
    local secondMinimum, secondMaximum = projectedPointBounds(
        points[edge.following],
        axisX,
        axisZ
    )
    if secondMinimum == nil then
        return nil, secondMaximum
    end
    return math.min(firstMinimum, secondMinimum),
        math.max(firstMaximum, secondMaximum)
end

local function projectedIntervalOverlapPairCount(
    points,
    edges,
    axisX,
    axisZ
)
    local minimums = {}
    local maximums = {}
    for index = 1, #edges do
        local minimum, maximum = projectedEdgeBounds(
            points,
            edges[index],
            axisX,
            axisZ
        )
        if minimum == nil then
            return nil, maximum
        end
        minimums[index] = minimum
        maximums[index] = maximum
    end
    return sortedIntervalOverlapPairCount(minimums, maximums)
end

local function derivedAxisLess(left, right)
    if left.lengthSquared ~= right.lengthSquared then
        return left.lengthSquared > right.lengthSquared
    elseif left.axisX ~= right.axisX then
        return left.axisX < right.axisX
    elseif left.axisZ ~= right.axisZ then
        return left.axisZ < right.axisZ
    end
    return left.index < right.index
end

local function axesEquivalent(firstX, firstZ, secondX, secondZ)
    local cross = firstX * secondZ - firstZ * secondX
    return finiteNumber(cross)
        and math.abs(cross) <= AXIS_EQUIVALENCE_TOLERANCE
end

local function derivedSweepAxes(points, edges)
    local candidates = {}
    for index = 1, #edges do
        local edge = edges[index]
        local first = points[edge.index]
        local second = points[edge.following]
        local deltaX = second.x - first.x
        local deltaZ = second.z - first.z
        local lengthSquared = deltaX * deltaX + deltaZ * deltaZ
        if finiteNumber(lengthSquared) and lengthSquared > 0 then
            local length = math.sqrt(lengthSquared)
            local axisX = -deltaZ / length
            local axisZ = deltaX / length
            if finiteNumber(length) and length > 0
                and finiteNumber(axisX) and finiteNumber(axisZ) then
                if axisX < 0 or (axisX == 0 and axisZ < 0) then
                    axisX = -axisX
                    axisZ = -axisZ
                end
                candidates[#candidates + 1] = {
                    axisX = canonicalZero(axisX),
                    axisZ = canonicalZero(axisZ),
                    lengthSquared = lengthSquared,
                    index = edge.index
                }
            end
        end
    end
    table.sort(candidates, derivedAxisLess)

    -- Long-edge normals are useful for strip-like or serpentine polygons.
    -- Select distinct directions in a winding-independent priority order and
    -- omit directions already represented by exact world X or Z sweeps.
    local selected = {}
    for candidateIndex = 1, #candidates do
        local candidate = candidates[candidateIndex]
        local duplicate = axesEquivalent(
            candidate.axisX,
            candidate.axisZ,
            1,
            0
        ) or axesEquivalent(
            candidate.axisX,
            candidate.axisZ,
            0,
            1
        )
        for selectedIndex = 1, #selected do
            local existing = selected[selectedIndex]
            if axesEquivalent(
                candidate.axisX,
                candidate.axisZ,
                existing.axisX,
                existing.axisZ
            ) then
                duplicate = true
                break
            end
        end
        if not duplicate then
            selected[#selected + 1] = candidate
            if #selected == DERIVED_AXIS_LIMIT then
                break
            end
        end
    end
    return selected
end

local function intervalEdgeLess(left, right)
    if left.intervalMinimum ~= right.intervalMinimum then
        return left.intervalMinimum < right.intervalMinimum
    elseif left.intervalMaximum ~= right.intervalMaximum then
        return left.intervalMaximum < right.intervalMaximum
    end
    return left.index < right.index
end

local function intervalTreeHeight(node)
    return node == nil and 0 or node.height
end

local function refreshIntervalTreeNode(node)
    local leftHeight = intervalTreeHeight(node.left)
    local rightHeight = intervalTreeHeight(node.right)
    node.height = math.max(leftHeight, rightHeight) + 1

    local subtreeMaximum = node.edge.intervalMaximum
    if node.left ~= nil
        and node.left.subtreeMaximum > subtreeMaximum then
        subtreeMaximum = node.left.subtreeMaximum
    end
    if node.right ~= nil
        and node.right.subtreeMaximum > subtreeMaximum then
        subtreeMaximum = node.right.subtreeMaximum
    end
    node.subtreeMaximum = subtreeMaximum
    return node
end

local function rotateIntervalTreeLeft(node)
    local replacement = node.right
    local transferred = replacement.left
    replacement.left = node
    node.right = transferred
    refreshIntervalTreeNode(node)
    return refreshIntervalTreeNode(replacement)
end

local function rotateIntervalTreeRight(node)
    local replacement = node.left
    local transferred = replacement.right
    replacement.right = node
    node.left = transferred
    refreshIntervalTreeNode(node)
    return refreshIntervalTreeNode(replacement)
end

local function balanceIntervalTree(node)
    if node == nil then
        return nil
    end
    refreshIntervalTreeNode(node)
    local balance = intervalTreeHeight(node.left)
        - intervalTreeHeight(node.right)
    if balance > 1 then
        if intervalTreeHeight(node.left.left)
            < intervalTreeHeight(node.left.right) then
            node.left = rotateIntervalTreeLeft(node.left)
        end
        return rotateIntervalTreeRight(node)
    elseif balance < -1 then
        if intervalTreeHeight(node.right.right)
            < intervalTreeHeight(node.right.left) then
            node.right = rotateIntervalTreeRight(node.right)
        end
        return rotateIntervalTreeLeft(node)
    end
    return node
end

local function insertIntervalTree(node, edge)
    if node == nil then
        return {
            edge = edge,
            height = 1,
            subtreeMaximum = edge.intervalMaximum
        }
    end
    if intervalEdgeLess(edge, node.edge) then
        node.left = insertIntervalTree(node.left, edge)
    else
        node.right = insertIntervalTree(node.right, edge)
    end
    return balanceIntervalTree(node)
end

local function minimumIntervalTreeNode(node)
    while node.left ~= nil do
        node = node.left
    end
    return node
end

local function removeIntervalTree(node, edge)
    if node == nil then
        return nil
    end
    if intervalEdgeLess(edge, node.edge) then
        node.left = removeIntervalTree(node.left, edge)
    elseif intervalEdgeLess(node.edge, edge) then
        node.right = removeIntervalTree(node.right, edge)
    else
        if node.left == nil then
            return node.right
        elseif node.right == nil then
            return node.left
        end
        local successor = minimumIntervalTreeNode(node.right)
        node.edge = successor.edge
        node.right = removeIntervalTree(node.right, successor.edge)
    end
    return balanceIntervalTree(node)
end

local function queryIntervalTree(node, minimum, maximum, result)
    if node == nil or node.subtreeMaximum < minimum then
        return
    end

    if node.left ~= nil and node.left.subtreeMaximum >= minimum then
        queryIntervalTree(node.left, minimum, maximum, result)
    end

    local edge = node.edge
    if edge.intervalMinimum <= maximum then
        if edge.intervalMaximum >= minimum then
            result[#result + 1] = edge
        end
        queryIntervalTree(node.right, minimum, maximum, result)
    end
end

local function edgeSweepMaximumLess(left, right)
    if left.maxSweep ~= right.maxSweep then
        return left.maxSweep < right.maxSweep
    elseif left.minSweep ~= right.minSweep then
        return left.minSweep < right.minSweep
    end
    return left.index < right.index
end

local function neighboringEdges(firstIndex, secondIndex, count)
    local difference = math.abs(firstIndex - secondIndex)
    return difference == 1 or difference == count - 1
end

local SWEEP_AMBIGUOUS = "sweepAmbiguous"

local function sweepCross(firstDeltaX, firstDeltaZ, secondDeltaX, secondDeltaZ)
    local firstProduct = firstDeltaX * secondDeltaZ
    local secondProduct = firstDeltaZ * secondDeltaX
    local cross = firstProduct - secondProduct
    local errorBound = PROJECTION_ROUNDING_FACTOR
        * (math.abs(firstProduct) + math.abs(secondProduct))
    return cross, errorBound
end

local function sweepCrossToPoint(edge, point)
    return sweepCross(
        edge.sweepDeltaX,
        edge.sweepDeltaZ,
        point.x - edge.sweepStartPoint.x,
        point.z - edge.sweepStartPoint.z
    )
end

local function simplicityEdgePair(points, first, second, count)
    if neighboringEdges(first.index, second.index, count) then
        return true
    end
    if first.maxX < second.minX or second.maxX < first.minX
        or first.maxZ < second.minZ or second.maxZ < first.minZ then
        return true
    end

    local relation, relationReason = exactSimplicityEdgeRelation(
        points,
        first,
        second
    )
    if relation == nil then
        return nil, relationReason
    end
    if relation ~= "disjoint" then
        return nil, "selfIntersectingPolygon"
    end
    return true
end

local function orderNodeHeight(node)
    return node == nil and 0 or node.height
end

local function refreshOrderNode(node)
    node.height = math.max(
        orderNodeHeight(node.left),
        orderNodeHeight(node.right)
    ) + 1
    return node
end

local function replaceOrderParent(state, oldNode, newNode)
    local parent = oldNode.parent
    if parent == nil then
        state.root = newNode
    elseif parent.left == oldNode then
        parent.left = newNode
    else
        parent.right = newNode
    end
    if newNode ~= nil then
        newNode.parent = parent
    end
end

local function rotateOrderLeft(state, node)
    local replacement = node.right
    local transferred = replacement.left
    replaceOrderParent(state, node, replacement)
    replacement.left = node
    node.parent = replacement
    node.right = transferred
    if transferred ~= nil then
        transferred.parent = node
    end
    refreshOrderNode(node)
    return refreshOrderNode(replacement)
end

local function rotateOrderRight(state, node)
    local replacement = node.left
    local transferred = replacement.right
    replaceOrderParent(state, node, replacement)
    replacement.right = node
    node.parent = replacement
    node.left = transferred
    if transferred ~= nil then
        transferred.parent = node
    end
    refreshOrderNode(node)
    return refreshOrderNode(replacement)
end

local function rebalanceOrderTree(state, node)
    while node ~= nil do
        refreshOrderNode(node)
        local balance = orderNodeHeight(node.left)
            - orderNodeHeight(node.right)
        if balance > 1 then
            if orderNodeHeight(node.left.left)
                < orderNodeHeight(node.left.right) then
                rotateOrderLeft(state, node.left)
            end
            node = rotateOrderRight(state, node)
        elseif balance < -1 then
            if orderNodeHeight(node.right.right)
                < orderNodeHeight(node.right.left) then
                rotateOrderRight(state, node.right)
            end
            node = rotateOrderLeft(state, node)
        end
        node = node.parent
    end
end

local function predecessorOrderNode(node)
    if node.left ~= nil then
        node = node.left
        while node.right ~= nil do
            node = node.right
        end
        return node
    end
    while node.parent ~= nil and node.parent.left == node do
        node = node.parent
    end
    return node.parent
end

local function successorOrderNode(node)
    if node.right ~= nil then
        node = node.right
        while node.left ~= nil do
            node = node.left
        end
        return node
    end
    while node.parent ~= nil and node.parent.right == node do
        node = node.parent
    end
    return node.parent
end

local function insertOrderEdge(state, edge, less)
    local parent = nil
    local cursor = state.root
    local insertLeft = false
    while cursor ~= nil do
        parent = cursor
        local isLess, lessReason = less(edge, cursor.edge)
        if isLess == nil then
            return nil, lessReason
        end
        insertLeft = isLess
        if isLess then
            cursor = cursor.left
        else
            cursor = cursor.right
        end
    end

    local node = {
        edge = edge,
        height = 1,
        parent = parent
    }
    if parent == nil then
        state.root = node
    elseif insertLeft then
        parent.left = node
    else
        parent.right = node
    end
    edge.orderNode = node
    rebalanceOrderTree(state, parent)
    return node
end

local function removeOrderNode(state, node)
    local removedEdge = node.edge
    if node.left ~= nil and node.right ~= nil then
        local replacement = successorOrderNode(node)
        node.edge = replacement.edge
        node.edge.orderNode = node
        node = replacement
    end

    local child = node.left or node.right
    local parent = node.parent
    replaceOrderParent(state, node, child)
    removedEdge.orderNode = nil
    node.left = nil
    node.right = nil
    node.parent = nil
    rebalanceOrderTree(state, parent)
end

local function checkOrderNodeNeighbors(points, node, count)
    local before = predecessorOrderNode(node)
    if before ~= nil then
        local valid, reason = simplicityEdgePair(
            points,
            before.edge,
            node.edge,
            count
        )
        if valid == nil then
            return nil, reason
        end
    end
    local after = successorOrderNode(node)
    if after ~= nil then
        local valid, reason = simplicityEdgePair(
            points,
            node.edge,
            after.edge,
            count
        )
        if valid == nil then
            return nil, reason
        end
    end
    return true
end

local function sweepEdgeLess(first, second, count)
    if first == second then
        return false
    end

    local cross, errorBound = sweepCrossToPoint(
        second,
        first.sweepStartPoint
    )
    if cross ~= 0 then
        if math.abs(cross) <= errorBound then
            return nil, SWEEP_AMBIGUOUS
        end
        -- The original-coordinate cross has the same sign as both selected
        -- positive-determinant X/Z sweep transforms. A negative sign places
        -- the new edge below the active edge.
        return cross < 0
    end

    if not samePoint(first.sweepStartPoint, second.sweepStartPoint) then
        return nil, SWEEP_AMBIGUOUS
    end
    if not neighboringEdges(first.index, second.index, count) then
        return nil, "selfIntersectingPolygon"
    end

    local slopeCross, slopeError = sweepCross(
        second.sweepDeltaX,
        second.sweepDeltaZ,
        first.sweepDeltaX,
        first.sweepDeltaZ
    )
    if slopeCross == 0 or math.abs(slopeCross) <= slopeError then
        return nil, SWEEP_AMBIGUOUS
    end
    return slopeCross < 0
end

local function compareOrderEdgeToPoint(edge, point)
    local cross, errorBound = sweepCrossToPoint(edge, point)
    if cross == 0 then
        if samePoint(point, edge.sweepStartPoint)
            or samePoint(point, edge.sweepEndPoint) then
            return 0
        end
        return nil, SWEEP_AMBIGUOUS
    end
    if math.abs(cross) <= errorBound then
        return nil, SWEEP_AMBIGUOUS
    end
    -- Positive means the query point is above the edge, so the active edge
    -- compares below the point.
    return cross > 0 and -1 or 1
end

local function lowerBoundOrderPoint(state, point)
    local cursor = state.root
    local found = nil
    while cursor ~= nil do
        local comparison, compareReason = compareOrderEdgeToPoint(
            cursor.edge,
            point
        )
        if comparison == nil then
            return nil, compareReason
        end
        if comparison >= 0 then
            found = cursor
            cursor = cursor.left
        else
            cursor = cursor.right
        end
    end
    return found
end

local function checkVerticalAgainstOrder(
    points,
    state,
    vertical,
    count
)
    local node, lowerReason = lowerBoundOrderPoint(
        state,
        vertical.minSweepPoint
    )
    if lowerReason ~= nil then
        return nil, lowerReason
    end
    while node ~= nil do
        local comparison, compareReason = compareOrderEdgeToPoint(
            node.edge,
            vertical.maxSweepPoint
        )
        if comparison == nil then
            return nil, compareReason
        end
        if comparison > 0 then
            break
        end
        local valid, validReason = simplicityEdgePair(
            points,
            vertical,
            node.edge,
            count
        )
        if valid == nil then
            return nil, validReason
        end
        node = successorOrderNode(node)
    end
    return true
end

local function eventGroup(eventByCoordinate, events, coordinate)
    local group = eventByCoordinate[coordinate]
    if group == nil then
        group = {
            coordinate = coordinate,
            starts = {},
            endings = {},
            verticals = {},
            vertexBySecondary = {}
        }
        eventByCoordinate[coordinate] = group
        events[#events + 1] = group
    end
    return group
end

local function prepareOrderSweep(points, edges)
    local verticalX = 0
    local verticalZ = 0
    for index = 1, #edges do
        local edge = edges[index]
        if edge.deltaX == 0 then
            verticalX = verticalX + 1
        end
        if edge.deltaZ == 0 then
            verticalZ = verticalZ + 1
        end
    end
    local useWorldX = verticalX <= verticalZ

    local events = {}
    local eventByCoordinate = {}
    for index = 1, #points do
        local point = points[index]
        local coordinate = useWorldX and point.x or point.z
        local secondary = useWorldX and point.z or -point.x
        local group = eventGroup(
            eventByCoordinate,
            events,
            coordinate
        )
        local existingIndex = rawget(group.vertexBySecondary, secondary)
        if existingIndex ~= nil then
            return nil, "selfIntersectingPolygon"
        end
        group.vertexBySecondary[secondary] = index
    end

    for index = 1, #edges do
        local edge = edges[index]
        local first = points[edge.index]
        local second = points[edge.following]
        local firstU
        local firstV
        local secondU
        local secondV
        if useWorldX then
            firstU, firstV = first.x, first.z
            secondU, secondV = second.x, second.z
        else
            firstU, firstV = first.z, -first.x
            secondU, secondV = second.z, -second.x
        end

        if firstU == secondU then
            edge.minSweep = math.min(firstV, secondV)
            edge.maxSweep = math.max(firstV, secondV)
            if firstV <= secondV then
                edge.minSweepPoint = first
                edge.maxSweepPoint = second
            else
                edge.minSweepPoint = second
                edge.maxSweepPoint = first
            end
            local group = eventGroup(
                eventByCoordinate,
                events,
                firstU
            )
            group.verticals[#group.verticals + 1] = edge
        else
            local startPoint
            local endPoint
            local startU
            local endU
            if firstU < secondU then
                startPoint, endPoint = first, second
                startU, endU = firstU, secondU
            else
                startPoint, endPoint = second, first
                startU, endU = secondU, firstU
            end
            edge.sweepStartPoint = startPoint
            edge.sweepEndPoint = endPoint
            edge.sweepDeltaX = endPoint.x - startPoint.x
            edge.sweepDeltaZ = endPoint.z - startPoint.z
            local startGroup = eventGroup(
                eventByCoordinate,
                events,
                startU
            )
            startGroup.starts[#startGroup.starts + 1] = edge
            local endGroup = eventGroup(
                eventByCoordinate,
                events,
                endU
            )
            endGroup.endings[#endGroup.endings + 1] = edge
        end
    end
    table.sort(events, function(left, right)
        return left.coordinate < right.coordinate
    end)
    return events
end

local function verticalEdgeLess(left, right)
    if left.minSweep ~= right.minSweep then
        return left.minSweep < right.minSweep
    elseif left.maxSweep ~= right.maxSweep then
        return left.maxSweep < right.maxSweep
    elseif left.minX ~= right.minX then
        return left.minX < right.minX
    elseif left.minZ ~= right.minZ then
        return left.minZ < right.minZ
    end
    return left.index < right.index
end

local function checkVerticalPairs(points, verticals, count)
    table.sort(verticals, verticalEdgeLess)
    for index = 2, #verticals do
        local current = verticals[index]
        local previousIndex = index - 1
        while previousIndex >= 1
            and verticals[previousIndex].maxSweep >= current.minSweep do
            local valid, validReason = simplicityEdgePair(
                points,
                verticals[previousIndex],
                current,
                count
            )
            if valid == nil then
                return nil, validReason
            end
            previousIndex = previousIndex - 1
        end
    end
    return true
end

local function validatePolygonSimplicityOrderSweep(points, edges)
    local count = #points
    local events, eventReason = prepareOrderSweep(points, edges)
    if events == nil then
        return nil, eventReason
    end
    local state = {root = nil}

    local function less(first, second)
        return sweepEdgeLess(first, second, count)
    end

    for eventIndex = 1, #events do
        local group = events[eventIndex]

        -- Zero-sweep-width edges exist only at this event coordinate. Query
        -- the left-limit active order first so contacts with ending edges are
        -- visible before their handles are removed.
        for verticalIndex = 1, #group.verticals do
            local valid, validReason = checkVerticalAgainstOrder(
                points,
                state,
                group.verticals[verticalIndex],
                count
            )
            if valid == nil then
                return nil, validReason
            end
        end

        for endingIndex = 1, #group.endings do
            local edge = group.endings[endingIndex]
            local node = edge.orderNode
            if node == nil then
                return nil, SWEEP_AMBIGUOUS
            end
            local before = predecessorOrderNode(node)
            local after = successorOrderNode(node)
            local valid, validReason = checkOrderNodeNeighbors(
                points,
                node,
                count
            )
            if valid == nil then
                return nil, validReason
            end
            removeOrderNode(state, node)
            if before ~= nil and after ~= nil then
                valid, validReason = simplicityEdgePair(
                    points,
                    before.edge,
                    after.edge,
                    count
                )
                if valid == nil then
                    return nil, validReason
                end
            end
        end

        -- All ending handles are gone, so equal-height insertions use their
        -- right-limit slope order without conflicting with a left-limit key.
        for startIndex = 1, #group.starts do
            local node, insertReason = insertOrderEdge(
                state,
                group.starts[startIndex],
                less
            )
            if node == nil then
                return nil, insertReason
            end
            local valid, validReason = checkOrderNodeNeighbors(
                points,
                node,
                count
            )
            if valid == nil then
                return nil, validReason
            end
        end

        local verticalValid, verticalReason = checkVerticalPairs(
            points,
            group.verticals,
            count
        )
        if verticalValid == nil then
            return nil, verticalReason
        end

        -- Repeat the vertical range query against the right-limit order so
        -- contacts with newly inserted edges cannot be hidden by event order.
        for verticalIndex = 1, #group.verticals do
            local valid, validReason = checkVerticalAgainstOrder(
                points,
                state,
                group.verticals[verticalIndex],
                count
            )
            if valid == nil then
                return nil, validReason
            end
        end
    end

    if state.root ~= nil then
        return nil, SWEEP_AMBIGUOUS
    end
    return true
end

local function validatePolygonSimplicityAdaptive(points, edges)
    local count = #points
    local xOverlapPairs = intervalOverlapPairCount(edges, "minX", "maxX")
    local sweepMinimumKey = "minX"
    local sweepMaximumKey = "maxX"
    local sweepComparator = edgeBoundsLessX
    local bestOverlapPairs = xOverlapPairs
    local zOverlapPairs = intervalOverlapPairCount(edges, "minZ", "maxZ")
    if zOverlapPairs < bestOverlapPairs then
        sweepMinimumKey = "minZ"
        sweepMaximumKey = "maxZ"
        sweepComparator = edgeBoundsLessZ
        bestOverlapPairs = zOverlapPairs
    end

    local bestDerivedAxis = nil
    -- Every edge interval overlaps the two neighboring edge intervals at its
    -- endpoints, producing exactly count distinct neighbor pairs. Once an
    -- axis reaches that lower bound, no additional candidate can improve it.
    if bestOverlapPairs > count then
        local derivedAxes = derivedSweepAxes(points, edges)
        for axisIndex = 1, #derivedAxes do
            local axis = derivedAxes[axisIndex]
            local overlapPairs = projectedIntervalOverlapPairCount(
                points,
                edges,
                axis.axisX,
                axis.axisZ
            )
            if overlapPairs ~= nil and overlapPairs < bestOverlapPairs then
                bestOverlapPairs = overlapPairs
                bestDerivedAxis = axis
                sweepMinimumKey = "minProjection"
                sweepMaximumKey = "maxProjection"
                sweepComparator = edgeBoundsLessProjection
                if bestOverlapPairs <= count then
                    break
                end
            end
        end
    end

    if bestDerivedAxis ~= nil then
        for index = 1, count do
            local minimum, maximum = projectedEdgeBounds(
                points,
                edges[index],
                bestDerivedAxis.axisX,
                bestDerivedAxis.axisZ
            )
            if minimum == nil then
                return nil, maximum
            end
            edges[index].minProjection = minimum
            edges[index].maxProjection = maximum
        end
    end

    local intervalMinimumKey
    local intervalMaximumKey
    if sweepMinimumKey == "minX" then
        intervalMinimumKey = "minZ"
        intervalMaximumKey = "maxZ"
    elseif sweepMinimumKey == "minZ" then
        intervalMinimumKey = "minX"
        intervalMaximumKey = "maxX"
    elseif xOverlapPairs <= zOverlapPairs then
        intervalMinimumKey = "minX"
        intervalMaximumKey = "maxX"
    else
        intervalMinimumKey = "minZ"
        intervalMaximumKey = "maxZ"
    end
    local endingEdges = {}
    for index = 1, count do
        local edge = edges[index]
        edge.minSweep = edge[sweepMinimumKey]
        edge.maxSweep = edge[sweepMaximumKey]
        edge.intervalMinimum = edge[intervalMinimumKey]
        edge.intervalMaximum = edge[intervalMaximumKey]
        endingEdges[index] = edge
    end
    table.sort(edges, sweepComparator)
    table.sort(endingEdges, edgeSweepMaximumLess)

    -- Conservative adaptive sweep broad phase: a real intersection must
    -- coexist on every linear projection. Sweep the lowest-overlap choice
    -- among exact X/Z and a bounded set of conservatively expanded long-edge
    -- normals. An augmented balanced interval tree queries the other exact
    -- coordinate without scanning every sweep-active edge; the remaining
    -- exact coordinate bound is checked directly. Equality remains active at
    -- every interval boundary. Every surviving non-neighbor pair uses the
    -- unchanged exact segment predicate.
    local activeTree = nil
    local endingIndex = 1
    local candidates = {}
    for sortedIndex = 1, count do
        local current = edges[sortedIndex]
        while endingIndex <= count
            and endingEdges[endingIndex].maxSweep < current.minSweep do
            activeTree = removeIntervalTree(
                activeTree,
                endingEdges[endingIndex]
            )
            endingIndex = endingIndex + 1
        end

        for clearIndex = 1, #candidates do
            candidates[clearIndex] = nil
        end
        queryIntervalTree(
            activeTree,
            current.intervalMinimum,
            current.intervalMaximum,
            candidates
        )
        for candidateIndex = 1, #candidates do
            local candidate = candidates[candidateIndex]
            local boundsDisjoint = candidate.maxX < current.minX
                or current.maxX < candidate.minX
                or candidate.maxZ < current.minZ
                or current.maxZ < candidate.minZ
            if not boundsDisjoint and not neighboringEdges(
                candidate.index,
                current.index,
                count
            ) then
                local relation, relationReason = exactSimplicityEdgeRelation(
                    points,
                    candidate,
                    current
                )
                if relation == nil then
                    return nil, relationReason
                end
                if relation ~= "disjoint" then
                    return nil, "selfIntersectingPolygon"
                end
            end
        end
        activeTree = insertIntervalTree(activeTree, current)
    end
    return true
end

local function validatePolygonSimplicity(points)
    local count = #points
    local edges = {}
    for index = 1, count do
        local following = index == count and 1 or index + 1
        local first = points[index]
        local second = points[following]
        edges[index] = {
            index = index,
            following = following,
            deltaX = second.x - first.x,
            deltaZ = second.z - first.z,
            minX = math.min(first.x, second.x),
            maxX = math.max(first.x, second.x),
            minZ = math.min(first.z, second.z),
            maxZ = math.max(first.z, second.z)
        }
    end
    local ordered, orderReason = validatePolygonSimplicityOrderSweep(
        points,
        edges
    )
    if ordered ~= nil then
        return ordered
    end
    if orderReason ~= SWEEP_AMBIGUOUS then
        return nil, orderReason
    end

    -- A cross sign close enough to binary64 cancellation that its geometric
    -- order cannot be certified never becomes a rejection. Fall back to the
    -- conservative multi-axis interval sweep, which enumerates a superset of
    -- all true intersections and applies the same exact segment oracle.
    return validatePolygonSimplicityAdaptive(points, edges)
end

local function validatePolygonGeometry(points)
    local count = #points
    for index = 1, count do
        local following = index == count and 1 or index + 1
        if samePoint(points[index], points[following]) then
            return nil, "duplicateAdjacentVertex"
        end
    end

    local areaTwice, areaReason = polygonAreaTwice(points)
    if areaTwice == nil then
        return nil, areaReason
    end
    if areaTwice == 0 then
        return nil, "zeroArea"
    end

    -- Adjacent edges may be collinear, but they may not reverse and overlap.
    for index = 1, count do
        local previous = index == 1 and count or index - 1
        local following = index == count and 1 or index + 1
        local cross, crossReason = crossProduct(
            points[index],
            points[previous],
            points[following]
        )
        if cross == nil then
            return nil, crossReason
        end
        if cross == 0 then
            local firstX = points[previous].x - points[index].x
            local firstZ = points[previous].z - points[index].z
            local secondX = points[following].x - points[index].x
            local secondZ = points[following].z - points[index].z
            local dot = firstX * secondX + firstZ * secondZ
            if not finiteNumber(dot) then
                return nil, "nonFiniteGeometry"
            end
            if dot > 0 then
                return nil, "degeneratePolygon"
            end
        end
    end

    return validatePolygonSimplicity(points)
end

local function normalizePolygon(policy, validation, value, exactItems)
    local count, shapeReason = denseArrayShape(
        value,
        exactItems or policy.maxPolygonPoints,
        exactItems or 3,
        exactItems
    )
    if count == nil then
        if exactItems ~= nil then
            return nil, "invalidQuadrilateral"
        elseif shapeReason == "tooManyItems" then
            return nil, "polygonTooLarge"
        elseif shapeReason == "tooFewItems" then
            return nil, "polygonTooSmall"
        end
        return nil, "invalidPolygon"
    end

    local acceptedArray, arrayReason = dependencyArrayShape(
        policy,
        validation,
        count,
        exactItems or policy.maxPolygonPoints
    )
    if acceptedArray == nil then
        return nil, arrayReason
    end

    local normalized = {}
    local seen = {}
    for index = 1, count do
        local sourcePoint = rawget(value, index)
        if type(sourcePoint) == "table" then
            if seen[sourcePoint] then
                return nil, "pointReused"
            end
            seen[sourcePoint] = true
        end

        local point, pointReason = normalizePoint(policy, validation, sourcePoint)
        if point == nil then
            return nil, pointReason
        end
        normalized[index] = point
    end

    local validGeometry, geometryReason = validatePolygonGeometry(normalized)
    if validGeometry == nil then
        return nil, geometryReason
    end
    return normalized
end

local function pointRelationInternal(point, polygon, epsilon)
    local count = #polygon
    for index = 1, count do
        local following = index == count and 1 or index + 1
        local onSegment, reason = pointOnSegment(
            point,
            polygon[index],
            polygon[following],
            epsilon
        )
        if onSegment == nil then
            return nil, reason
        end
        if onSegment then
            return "boundary"
        end
    end

    local inside = false
    for index = 1, count do
        local following = index == count and 1 or index + 1
        local first = polygon[index]
        local second = polygon[following]
        if (first.z > point.z) ~= (second.z > point.z) then
            local denominator = second.z - first.z
            local parameter = (point.z - first.z) / denominator
            local intersectionX = first.x + parameter * (second.x - first.x)
            if not finiteNumber(denominator) or not finiteNumber(parameter)
                or not finiteNumber(intersectionX) then
                return nil, "nonFiniteGeometry"
            end
            if intersectionX > point.x then
                inside = not inside
            end
        end
    end
    return inside and "inside" or "outside"
end

local function parameterOnSegment(point, startPoint, endPoint)
    local deltaX = endPoint.x - startPoint.x
    local deltaZ = endPoint.z - startPoint.z
    local parameter
    if math.abs(deltaX) >= math.abs(deltaZ) then
        if deltaX == 0 then
            return nil, "nonFiniteGeometry"
        end
        parameter = (point.x - startPoint.x) / deltaX
    else
        if deltaZ == 0 then
            return nil, "nonFiniteGeometry"
        end
        parameter = (point.z - startPoint.z) / deltaZ
    end
    if not finiteNumber(parameter) then
        return nil, "nonFiniteGeometry"
    end
    if parameter < 0 then
        return 0
    elseif parameter > 1 then
        return 1
    end
    return parameter
end

local function appendTouchParameters(parameters, quadStart, quadEnd,
        fieldStart, fieldEnd, epsilon)
    local fieldStartOnQuad, firstReason = pointOnSegment(
        fieldStart,
        quadStart,
        quadEnd,
        epsilon
    )
    if fieldStartOnQuad == nil then
        return nil, firstReason
    end
    if fieldStartOnQuad then
        local parameter, reason = parameterOnSegment(
            fieldStart,
            quadStart,
            quadEnd
        )
        if parameter == nil then
            return nil, reason
        end
        parameters[#parameters + 1] = parameter
    end

    local fieldEndOnQuad, secondReason = pointOnSegment(
        fieldEnd,
        quadStart,
        quadEnd,
        epsilon
    )
    if fieldEndOnQuad == nil then
        return nil, secondReason
    end
    if fieldEndOnQuad then
        local parameter, reason = parameterOnSegment(
            fieldEnd,
            quadStart,
            quadEnd
        )
        if parameter == nil then
            return nil, reason
        end
        parameters[#parameters + 1] = parameter
    end

    local quadStartOnField, thirdReason = pointOnSegment(
        quadStart,
        fieldStart,
        fieldEnd,
        epsilon
    )
    if quadStartOnField == nil then
        return nil, thirdReason
    end
    if quadStartOnField then
        parameters[#parameters + 1] = 0
    end

    local quadEndOnField, fourthReason = pointOnSegment(
        quadEnd,
        fieldStart,
        fieldEnd,
        epsilon
    )
    if quadEndOnField == nil then
        return nil, fourthReason
    end
    if quadEndOnField then
        parameters[#parameters + 1] = 1
    end
    return true
end

local function containedEdgeExcursions(quad, quadRelations, polygon, epsilon)
    local quadCount = #quad
    local polygonCount = #polygon
    for quadIndex = 1, quadCount do
        local quadFollowing = quadIndex == quadCount and 1 or quadIndex + 1
        if quadRelations[quadIndex] ~= "outside"
            and quadRelations[quadFollowing] ~= "outside" then
            local parameters = {0, 1}
            for polygonIndex = 1, polygonCount do
                local polygonFollowing = polygonIndex == polygonCount
                    and 1 or polygonIndex + 1
                local relation, relationReason = segmentRelationInternal(
                    quad[quadIndex],
                    quad[quadFollowing],
                    polygon[polygonIndex],
                    polygon[polygonFollowing],
                    epsilon
                )
                if relation == nil then
                    return nil, relationReason
                end
                if relation == "touch" then
                    local appended, appendReason = appendTouchParameters(
                        parameters,
                        quad[quadIndex],
                        quad[quadFollowing],
                        polygon[polygonIndex],
                        polygon[polygonFollowing],
                        epsilon
                    )
                    if appended == nil then
                        return nil, appendReason
                    end
                end
            end

            table.sort(parameters)
            for parameterIndex = 1, #parameters - 1 do
                local first = parameters[parameterIndex]
                local second = parameters[parameterIndex + 1]
                if second > first then
                    local middle = (first + second) / 2
                    local sample = {
                        x = quad[quadIndex].x
                            + (quad[quadFollowing].x - quad[quadIndex].x) * middle,
                        z = quad[quadIndex].z
                            + (quad[quadFollowing].z - quad[quadIndex].z) * middle
                    }
                    if not finiteNumber(middle) or not finiteNumber(sample.x)
                        or not finiteNumber(sample.z) then
                        return nil, "nonFiniteGeometry"
                    end
                    local sampleRelation, sampleReason = pointRelationInternal(
                        sample,
                        polygon,
                        epsilon
                    )
                    if sampleRelation == nil then
                        return nil, sampleReason
                    end
                    if sampleRelation == "outside" then
                        return true
                    end
                end
            end
        end
    end
    return false
end

local function classifyInternal(quad, polygon, epsilon)
    local quadRelations = {}
    local insideCount = 0
    local boundaryCount = 0
    local outsideCount = 0
    for index = 1, #quad do
        local relation, reason = pointRelationInternal(quad[index], polygon, epsilon)
        if relation == nil then
            return nil, reason
        end
        quadRelations[index] = relation
        if relation == "inside" then
            insideCount = insideCount + 1
        elseif relation == "boundary" then
            boundaryCount = boundaryCount + 1
        else
            outsideCount = outsideCount + 1
        end
    end

    local hasTouch = false
    for quadIndex = 1, #quad do
        local quadFollowing = quadIndex == #quad and 1 or quadIndex + 1
        for polygonIndex = 1, #polygon do
            local polygonFollowing = polygonIndex == #polygon
                and 1 or polygonIndex + 1
            local relation, reason = segmentRelationInternal(
                quad[quadIndex],
                quad[quadFollowing],
                polygon[polygonIndex],
                polygon[polygonFollowing],
                epsilon
            )
            if relation == nil then
                return nil, reason
            end
            if relation == "cross" or relation == "overlap" then
                return "crossing"
            elseif relation == "touch" then
                hasTouch = true
            end
        end
    end

    local excursion, excursionReason = containedEdgeExcursions(
        quad,
        quadRelations,
        polygon,
        epsilon
    )
    if excursion == nil then
        return nil, excursionReason
    end
    if excursion then
        return "crossing"
    end

    if outsideCount == 0 then
        if boundaryCount > 0 or hasTouch then
            return "boundary"
        end
        return "inside"
    end
    if insideCount > 0 or boundaryCount > 0 or hasTouch then
        return "crossing"
    end

    -- With disjoint edges and every work vertex outside, a field vertex inside
    -- the work polygon is the remaining overlap case: field-inside-work.
    for index = 1, #polygon do
        local relation, reason = pointRelationInternal(polygon[index], quad, epsilon)
        if relation == nil then
            return nil, reason
        end
        if relation ~= "outside" then
            return "crossing"
        end
    end
    return "outside"
end

local function publicCall(callback)
    local guardPolicy = nil
    local guardValidation = nil
    local function registerGuard(policy, validation)
        guardPolicy = policy
        guardValidation = validation
    end
    local ok, first, second = pcall(callback, registerGuard)
    if guardPolicy ~= nil then
        local dependencyReason = dependencyStateReason(
            guardPolicy,
            guardValidation
        )
        if dependencyReason ~= nil then
            return nil, dependencyReason
        end
    end
    if not ok then
        return nil, "geometryFailure"
    end
    return first, second
end

function Geometry.point(value)
    return publicCall(function(registerGuard)
        local policy, validation, reason = resolvePolicy(registerGuard)
        if policy == nil then
            return nil, reason
        end
        return normalizePoint(policy, validation, value)
    end)
end

function Geometry.quadrilateral(startPoint, widthPoint, heightPoint)
    return publicCall(function(registerGuard)
        local policy, validation, reason = resolvePolicy(registerGuard)
        if policy == nil then
            return nil, reason
        end

        local start, startReason = normalizePoint(policy, validation, startPoint)
        if start == nil then
            return nil, startReason
        end
        local width, widthReason = normalizePoint(policy, validation, widthPoint)
        if width == nil then
            return nil, widthReason
        end
        local height, heightReason = normalizePoint(policy, validation, heightPoint)
        if height == nil then
            return nil, heightReason
        end

        local xSum = width.x + height.x
        local zSum = width.z + height.z
        local oppositeX = xSum - start.x
        local oppositeZ = zSum - start.z
        if not finiteNumber(xSum) or not finiteNumber(zSum)
            or not finiteNumber(oppositeX) or not finiteNumber(oppositeZ) then
            return nil, "nonFiniteGeometry"
        end
        if oppositeX < -policy.maxWorldCoordinate
            or oppositeX > policy.maxWorldCoordinate
            or oppositeZ < -policy.maxWorldCoordinate
            or oppositeZ > policy.maxWorldCoordinate then
            return nil, "coordinateOutOfRange"
        end
        local opposite = {
            x = canonicalZero(oppositeX),
            z = canonicalZero(oppositeZ)
        }

        local points = {start, width, opposite, height}
        for firstIndex = 1, 4 do
            for secondIndex = firstIndex + 1, 4 do
                if samePoint(points[firstIndex], points[secondIndex]) then
                    return nil, "duplicateVertex"
                end
            end
        end

        local valid, geometryReason = validatePolygonGeometry(points)
        if valid == nil then
            return nil, geometryReason
        end
        return points
    end)
end

function Geometry.polygon(points)
    return publicCall(function(registerGuard)
        local policy, validation, reason = resolvePolicy(registerGuard)
        if policy == nil then
            return nil, reason
        end
        return normalizePolygon(policy, validation, points)
    end)
end

function Geometry.pointRelation(point, polygon, epsilon)
    return publicCall(function(registerGuard)
        local policy, validation, reason = resolvePolicy(registerGuard)
        if policy == nil then
            return nil, reason
        end
        local normalizedPoint, pointReason = normalizePoint(
            policy,
            validation,
            point
        )
        if normalizedPoint == nil then
            return nil, pointReason
        end
        local normalizedPolygon, polygonReason = normalizePolygon(
            policy,
            validation,
            polygon
        )
        if normalizedPolygon == nil then
            return nil, polygonReason
        end
        local acceptedEpsilon, epsilonReason = validateEpsilon(
            policy,
            validation,
            epsilon
        )
        if acceptedEpsilon == nil then
            return nil, epsilonReason
        end
        return pointRelationInternal(
            normalizedPoint,
            normalizedPolygon,
            acceptedEpsilon
        )
    end)
end

function Geometry.segmentRelation(a, b, c, d, epsilon)
    return publicCall(function(registerGuard)
        local policy, validation, reason = resolvePolicy(registerGuard)
        if policy == nil then
            return nil, reason
        end

        local normalized = {}
        local values = {a, b, c, d}
        for index = 1, 4 do
            local point, pointReason = normalizePoint(
                policy,
                validation,
                values[index]
            )
            if point == nil then
                return nil, pointReason
            end
            normalized[index] = point
        end
        local acceptedEpsilon, epsilonReason = validateEpsilon(
            policy,
            validation,
            epsilon
        )
        if acceptedEpsilon == nil then
            return nil, epsilonReason
        end
        return segmentRelationInternal(
            normalized[1],
            normalized[2],
            normalized[3],
            normalized[4],
            acceptedEpsilon
        )
    end)
end

function Geometry.classifyQuadrilateral(quad, polygon, epsilon)
    return publicCall(function(registerGuard)
        local policy, validation, reason = resolvePolicy(registerGuard)
        if policy == nil then
            return nil, reason
        end
        local normalizedQuad, quadReason = normalizePolygon(
            policy,
            validation,
            quad,
            4
        )
        if normalizedQuad == nil then
            return nil, quadReason
        end
        local normalizedPolygon, polygonReason = normalizePolygon(
            policy,
            validation,
            polygon
        )
        if normalizedPolygon == nil then
            return nil, polygonReason
        end
        local acceptedEpsilon, epsilonReason = validateEpsilon(
            policy,
            validation,
            epsilon
        )
        if acceptedEpsilon == nil then
            return nil, epsilonReason
        end
        return classifyInternal(
            normalizedQuad,
            normalizedPolygon,
            acceptedEpsilon
        )
    end)
end

FieldProfitabilityLedger.Core.Geometry = Geometry

return Geometry
