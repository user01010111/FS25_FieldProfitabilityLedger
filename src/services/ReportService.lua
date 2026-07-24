-- Detached presentation queries for the single-player ledger.
-- This service never mutates the Ledger and never recomputes category totals.

FieldProfitabilityLedger = FieldProfitabilityLedger or {}
FieldProfitabilityLedger.Services = FieldProfitabilityLedger.Services or {}

local ReportService = {}
ReportService.__index = ReportService

local DETAIL_OPTION_KEYS = {
    includeExcluded = true,
    includeLive = true,
    recordLimit = true,
    recordOffset = true
}

local SCENARIO_OPTION_KEYS = {
    allocated = true,
    def = true,
    direct = true,
    fuel = true,
    inputs = true
}

local COMPARISON_OPTION_KEYS = {
    descending = true,
    limit = true,
    offset = true,
    sortBy = true
}

local COMPARISON_SORT_KEYS = {
    costPerHa = true,
    field = true,
    marginPerHa = true,
    newest = true,
    valuePerHa = true,
    yieldPerHa = true
}

local CYCLE_TABLE_OPTION_KEYS = {
    crop = true,
    descending = true,
    farmId = true,
    groupByField = true,
    includeLive = true,
    limit = true,
    offset = true,
    quality = true,
    scenario = true,
    scope = true,
    search = true,
    sortBy = true,
    state = true,
    states = true
}

local CYCLE_TABLE_SORT_KEYS = {
    area = true,
    costPerHa = true,
    crop = true,
    field = true,
    marginPerHa = true,
    period = true,
    quality = true,
    state = true,
    valuePerHa = true,
    yieldPerHa = true
}

local CYCLE_TABLE_SCENARIO_KEYS = {
    allocated = true,
    def = true,
    direct = true,
    fuel = true,
    inputs = true
}

local SECTION_BY_RECORD_TYPE = {
    operation = "operations",
    input = "inputs",
    harvest = "harvest",
    machinery = "machinery",
    labour = "labour",
    allocation = "allocations",
    valuation = "valuations"
}

local function dependencies()
    local namespace = rawget(_G, "FieldProfitabilityLedger")
    local core = type(namespace) == "table" and rawget(namespace, "Core") or nil
    local constants = type(core) == "table" and rawget(core, "Constants") or nil
    local accounting = type(core) == "table" and rawget(core, "Accounting") or nil
    local serialization = type(core) == "table" and rawget(core, "Serialization") or nil
    if type(constants) ~= "table"
        or type(accounting) ~= "table"
        or type(accounting.grossMargin) ~= "function"
        or type(accounting.yieldPerArea) ~= "function"
        or type(accounting.costPerArea) ~= "function"
        or type(serialization) ~= "table"
        or type(serialization.sortedKeys) ~= "function" then
        return nil, "reportDependencyUnavailable"
    end
    return constants, accounting, serialization
end

local function knownOptions(value, accepted)
    if value == nil then return {} end
    if type(value) ~= "table" or getmetatable(value) ~= nil then
        return nil
    end
    for key in next, value do
        if type(key) ~= "string" or accepted[key] ~= true then return nil end
    end
    return value
end

local function copyMap(value)
    local result = {}
    for key, item in pairs(value or {}) do result[key] = item end
    return result
end

local function copyArray(value)
    local result = {}
    for index, item in ipairs(value or {}) do result[index] = item end
    return result
end

local function detached(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] ~= nil then return seen[value] end
    local result = {}
    seen[value] = result
    for key, item in pairs(value) do
        result[detached(key, seen)] = detached(item, seen)
    end
    return result
end

local function attachCycleAlias(ledger, cycle)
    local alias, reason = ledger:getAlias(cycle.landKey)
    if alias == nil and reason ~= "aliasNotFound" then return nil, reason end
    cycle.alias = alias
    return true
end

local function finiteNumber(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

local function boundedInteger(value, minimum, maximum)
    if not finiteNumber(value) or value ~= math.floor(value)
        or value < minimum or value > maximum then
        return nil
    end
    return value
end

local function qualityClass(constants, counts, cycleQuality)
    if (counts[constants.QUALITY_CLASS.Unsupported] or 0) > 0 then
        return constants.QUALITY_CLASS.Unsupported
    end
    if cycleQuality == constants.QUALITY_CLASS.Unsupported then
        return constants.QUALITY_CLASS.Unsupported
    end
    if (counts[constants.QUALITY_CLASS.Partial] or 0) > 0
        or cycleQuality == constants.QUALITY_CLASS.Partial then
        return constants.QUALITY_CLASS.Partial
    end
    return constants.QUALITY_CLASS.Complete
end

local function categorySections(constants, totals)
    local sections = {
        observed = {}, direct = {}, valued = {}, allocated = {}, estimated = {}
    }
    local keyByClass = {
        [constants.ACCOUNTING_CLASS.Observed] = "observed",
        [constants.ACCOUNTING_CLASS.Direct] = "direct",
        [constants.ACCOUNTING_CLASS.Valued] = "valued",
        [constants.ACCOUNTING_CLASS.Allocated] = "allocated",
        [constants.ACCOUNTING_CLASS.Estimated] = "estimated"
    }
    for _, total in ipairs(totals or {}) do
        local section = sections[keyByClass[total.accountingClass]]
        if section ~= nil then section[#section + 1] = total end
    end
    return sections
end

local function findAmount(totals, accountingClass, category, unit, direction)
    for _, total in ipairs(totals or {}) do
        if total.accountingClass == accountingClass
            and total.category == category
            and total.unit == unit
            and total.direction == direction then
            return total.amount
        end
    end
    return nil
end

local function summaryFromQuery(constants, accounting, query)
    local totals = copyArray(query.categoryTotals)
    local counts = copyMap(query.qualityCounts)
    local harvested = findAmount(
        totals,
        constants.ACCOUNTING_CLASS.Observed,
        constants.CATEGORY.harvest,
        constants.UNIT.Litres,
        nil
    )
    local harvestedArea = findAmount(
        totals,
        constants.ACCOUNTING_CLASS.Observed,
        "ordinaryArableHarvest",
        constants.UNIT.Hectares,
        nil
    )
    local yieldValue, yieldReason = nil, "harvestOrAreaUnavailable"
    if harvested ~= nil and harvestedArea ~= nil then
        yieldValue, yieldReason = accounting.yieldPerArea(
            harvested,
            harvestedArea,
            constants.DEFAULT_EPSILON
        )
    end
    return {
        cycle = query.cycle,
        categoryTotals = totals,
        categorySections = categorySections(constants, totals),
        qualityCounts = counts,
        qualityClass = qualityClass(constants, counts, query.cycle.qualityClass),
        compactedRecordCount = query.compactedRecordCount,
        directReplacementOverlap = query.directReplacementOverlap,
        yieldLitresPerHa = yieldValue,
        yieldReason = yieldValue == nil and yieldReason or nil,
        correctionCount = #(query.corrections or {}),
        exclusionCount = #(query.exclusions or {})
    }
end

local function scenarioParts(constants, query)
    local totals = query.categoryTotals
    local parts = {
        directReplacementOverlap = query.directReplacementOverlap == true,
        allocatedCosts = {}
    }
    parts.estimatedHarvestValue = findAmount(
        totals, constants.ACCOUNTING_CLASS.Estimated,
        constants.CATEGORY.estimatedHarvestValue,
        constants.UNIT.Money, constants.DIRECTION.IncomeValue
    )
    parts.directObservedCosts = findAmount(
        totals, constants.ACCOUNTING_CLASS.Direct,
        constants.CATEGORY.directObservedCost,
        constants.UNIT.Money, constants.DIRECTION.Expense
    )
    parts.replacementValuedInputs = findAmount(
        totals, constants.ACCOUNTING_CLASS.Valued,
        constants.CATEGORY.inputReplacementValue,
        constants.UNIT.Money, constants.DIRECTION.Expense
    )
    parts.replacementFuelValue = findAmount(
        totals, constants.ACCOUNTING_CLASS.Valued,
        constants.CATEGORY.fuelReplacementValue,
        constants.UNIT.Money, constants.DIRECTION.Expense
    )
    parts.replacementDefValue = findAmount(
        totals, constants.ACCOUNTING_CLASS.Valued,
        constants.CATEGORY.defReplacementValue,
        constants.UNIT.Money, constants.DIRECTION.Expense
    )
    for _, total in ipairs(totals or {}) do
        if total.accountingClass == constants.ACCOUNTING_CLASS.Allocated
            and total.unit == constants.UNIT.Money
            and total.direction == constants.DIRECTION.Expense then
            parts.allocatedCosts[total.category] = total.amount
        end
    end
    return parts
end

local function defaultInclusion(parts)
    local allocated = {}
    for key in pairs(parts.allocatedCosts) do allocated[key] = true end
    return {
        direct = parts.directObservedCosts ~= nil,
        inputs = parts.replacementValuedInputs ~= nil,
        fuel = parts.replacementFuelValue ~= nil,
        def = parts.replacementDefValue ~= nil,
        allocated = allocated
    }
end

local function normalizeInclusion(value, parts)
    local options = knownOptions(value, SCENARIO_OPTION_KEYS)
    if options == nil then return nil, "invalidScenarioOptions" end
    local result = defaultInclusion(parts)
    for _, key in ipairs({"direct", "inputs", "fuel", "def"}) do
        if rawget(options, key) ~= nil then
            if type(rawget(options, key)) ~= "boolean" then
                return nil, "invalidScenarioOptions"
            end
            result[key] = rawget(options, key)
        end
    end
    if rawget(options, "allocated") ~= nil then
        local requested = rawget(options, "allocated")
        if type(requested) ~= "table" or getmetatable(requested) ~= nil then
            return nil, "invalidScenarioOptions"
        end
        result.allocated = {}
        for key, included in pairs(requested) do
            if type(key) ~= "string" or type(included) ~= "boolean" then
                return nil, "invalidScenarioOptions"
            end
            result.allocated[key] = included
        end
    end
    return result
end

local function scenarioFromQuery(constants, accounting, serialization, query, options)
    local parts = scenarioParts(constants, query)
    if parts.estimatedHarvestValue == nil then
        return {
            available = false,
            reason = "estimatedHarvestValueUnavailable",
            parts = parts,
            inclusion = defaultInclusion(parts)
        }
    end
    local inclusion, reason = normalizeInclusion(options, parts)
    if inclusion == nil then return nil, reason end
    local margin, result = accounting.grossMargin(parts, inclusion)
    if margin == nil then
        return {
            available = false,
            reason = result,
            parts = parts,
            inclusion = inclusion
        }
    end
    local costPerHa, costReason = nil, "cycleAreaUnavailable"
    if query.cycle.cycleAreaHa ~= nil then
        costPerHa, costReason = accounting.costPerArea(
            result.totalSelectedCosts,
            query.cycle.cycleAreaHa,
            constants.DEFAULT_EPSILON
        )
    end
    local allocatedKeys, keysReason = serialization.sortedKeys(parts.allocatedCosts)
    if allocatedKeys == nil then return nil, keysReason end
    return {
        available = true,
        accountingClass = constants.ACCOUNTING_CLASS.Estimated,
        result = result,
        inclusion = inclusion,
        parts = parts,
        allocatedKeys = allocatedKeys,
        cycleCostPerHa = costPerHa,
        cycleCostPerHaReason = costPerHa == nil and costReason or nil
    }
end

local function signedMoneyPerArea(accounting, amount, area, epsilon)
    if not finiteNumber(amount) then return nil, "amountUnavailable" end
    if amount >= 0 then
        return accounting.costPerArea(amount, area, epsilon)
    end
    local magnitude, reason = accounting.costPerArea(-amount, area, epsilon)
    if magnitude == nil then return nil, reason end
    return -magnitude
end

local function comparisonRow(constants, accounting, serialization, query)
    local summary = summaryFromQuery(constants, accounting, query)
    local scenario, reason = scenarioFromQuery(
        constants, accounting, serialization, query, nil)
    if scenario == nil then return nil, reason end
    local row = {
        cycle = summary.cycle,
        qualityClass = summary.qualityClass,
        yieldLitresPerHa = summary.yieldLitresPerHa,
        scenarioAvailable = scenario.available == true,
        scenarioReason = scenario.available == true and nil or scenario.reason
    }
    if scenario.available then
        row.estimatedHarvestValue = scenario.result.estimatedHarvestValue
        row.totalSelectedCosts = scenario.result.totalSelectedCosts
        row.estimatedGrossMargin = scenario.result.estimatedGrossMargin
        row.costPerHa = scenario.cycleCostPerHa
        if query.cycle.cycleAreaHa ~= nil then
            row.valuePerHa = accounting.costPerArea(
                scenario.result.estimatedHarvestValue,
                query.cycle.cycleAreaHa,
                constants.DEFAULT_EPSILON
            )
            row.marginPerHa = signedMoneyPerArea(
                accounting,
                scenario.result.estimatedGrossMargin,
                query.cycle.cycleAreaHa,
                constants.DEFAULT_EPSILON
            )
        end
    end
    return row
end

local function meanMetrics(rows)
    local keys = {"yieldLitresPerHa", "valuePerHa", "costPerHa", "marginPerHa"}
    local averages, counts = {}, {}
    for _, key in ipairs(keys) do
        local mean, count = nil, 0
        for _, row in ipairs(rows) do
            local value = row[key]
            if finiteNumber(value) then
                count = count + 1
                mean = mean == nil and value or mean + (value - mean) / count
            end
        end
        averages[key] = mean
        counts[key] = count
    end
    return averages, counts
end

local function compareField(left, right)
    local leftField = left.cycle.fieldId
    local rightField = right.cycle.fieldId
    if leftField ~= rightField then
        if leftField == nil then return false end
        if rightField == nil then return true end
        return leftField < rightField
    end
    local leftFarmland = left.cycle.farmlandId or 0
    local rightFarmland = right.cycle.farmlandId or 0
    if leftFarmland ~= rightFarmland then return leftFarmland < rightFarmland end
    if left.cycle.landKey ~= right.cycle.landKey then
        return tostring(left.cycle.landKey) < tostring(right.cycle.landKey)
    end
    return tostring(left.cycle.id) < tostring(right.cycle.id)
end

local function sortComparisonRows(rows, sortBy, descending)
    local metricBySort = {
        costPerHa = "costPerHa",
        marginPerHa = "marginPerHa",
        newest = "startMissionTime",
        valuePerHa = "valuePerHa",
        yieldPerHa = "yieldLitresPerHa"
    }
    if sortBy == "field" then
        table.sort(rows, function(left, right)
            if descending then return compareField(right, left) end
            return compareField(left, right)
        end)
        return
    end
    local metric = metricBySort[sortBy]
    table.sort(rows, function(left, right)
        local leftValue = metric == "startMissionTime"
            and left.cycle.startMissionTime or left[metric]
        local rightValue = metric == "startMissionTime"
            and right.cycle.startMissionTime or right[metric]
        local leftAvailable = finiteNumber(leftValue)
        local rightAvailable = finiteNumber(rightValue)
        if leftAvailable ~= rightAvailable then return leftAvailable end
        if leftAvailable and leftValue ~= rightValue then
            if descending then
                return leftValue > rightValue
            end
            return leftValue < rightValue
        end
        return compareField(left, right)
    end)
end

local function cycleTableScenarioOptions(value)
    local accepted = knownOptions(value, CYCLE_TABLE_SCENARIO_KEYS)
    if accepted == nil then return nil, "invalidCycleTableOptions" end
    local result = {
        allocated = true,
        def = true,
        direct = true,
        fuel = true,
        inputs = true
    }
    for key in pairs(result) do
        if rawget(accepted, key) ~= nil then
            if type(rawget(accepted, key)) ~= "boolean" then
                return nil, "invalidCycleTableOptions"
            end
            result[key] = rawget(accepted, key)
        end
    end
    return result
end

local function cycleTableScenarioKey(options)
    return table.concat({
        options.direct and "1" or "0",
        options.inputs and "1" or "0",
        options.fuel and "1" or "0",
        options.def and "1" or "0",
        options.allocated and "1" or "0"
    }, "")
end

local function tableScenarioFromQuery(
        constants, accounting, serialization, query, switches)
    local parts = scenarioParts(constants, query)
    local allocated = {}
    for key in pairs(parts.allocatedCosts) do
        allocated[key] = switches.allocated
    end
    return scenarioFromQuery(constants, accounting, serialization, query, {
        direct=switches.direct and parts.directObservedCosts ~= nil,
        inputs=switches.inputs and parts.replacementValuedInputs ~= nil,
        fuel=switches.fuel and parts.replacementFuelValue ~= nil,
        def=switches.def and parts.replacementDefValue ~= nil,
        allocated=allocated
    })
end

local function cycleTableRow(
        constants, accounting, serialization, query, switches)
    local summary = summaryFromQuery(constants, accounting, query)
    local scenario, reason = tableScenarioFromQuery(
        constants, accounting, serialization, query, switches)
    if scenario == nil then return nil, reason end
    local row = summary
    row.scenarioAvailable = scenario.available == true
    row.scenarioReason = scenario.available and nil or scenario.reason
    row.valuePerHaReason = "estimatedHarvestValueUnavailable"
    row.costPerHaReason = scenario.available and scenario.cycleCostPerHaReason
        or scenario.reason
    row.marginPerHaReason = scenario.available and "cycleAreaUnavailable"
        or scenario.reason
    if scenario.available then
        row.estimatedHarvestValue = scenario.result.estimatedHarvestValue
        row.totalSelectedCosts = scenario.result.totalSelectedCosts
        row.estimatedGrossMargin = scenario.result.estimatedGrossMargin
        row.costPerHa = scenario.cycleCostPerHa
        if row.costPerHa ~= nil then row.costPerHaReason = nil end
        local area = query.cycle.cycleAreaHa
        if area ~= nil then
            row.valuePerHa, row.valuePerHaReason = accounting.costPerArea(
                scenario.result.estimatedHarvestValue,
                area,
                constants.DEFAULT_EPSILON)
            row.marginPerHa, row.marginPerHaReason = signedMoneyPerArea(
                accounting,
                scenario.result.estimatedGrossMargin,
                area,
                constants.DEFAULT_EPSILON)
        end
    end
    return row
end

local function normalizedText(value)
    if value == nil then return nil end
    if type(value) ~= "string" or #value > 128 then return false end
    local result = string.lower(value:match("^%s*(.-)%s*$"))
    return result ~= "" and result or nil
end

local function cycleSearchText(row)
    local cycle = row.cycle or {}
    local landLabel = ""
    if cycle.fieldKind == "base" and cycle.fieldId ~= nil then
        landLabel = "field " .. tostring(cycle.fieldId)
    elseif cycle.farmlandId ~= nil then
        landLabel = "parcel " .. tostring(cycle.farmlandId)
    end
    return string.lower(table.concat({
        tostring(cycle.alias or ""),
        landLabel,
        tostring(cycle.fieldId or ""),
        tostring(cycle.farmlandId or ""),
        tostring(cycle.landKey or ""),
        tostring(cycle.fruitType or "")
    }, " "))
end

local function compareCycleField(left, right)
    local leftCycle, rightCycle = left.cycle, right.cycle
    local leftField, rightField = leftCycle.fieldId, rightCycle.fieldId
    if leftField ~= rightField then
        if leftField == nil then return 1 end
        if rightField == nil then return -1 end
        return leftField < rightField and -1 or 1
    end
    local leftFarmland = leftCycle.farmlandId or 0
    local rightFarmland = rightCycle.farmlandId or 0
    if leftFarmland ~= rightFarmland then
        return leftFarmland < rightFarmland and -1 or 1
    end
    local leftLand, rightLand = tostring(leftCycle.landKey),
        tostring(rightCycle.landKey)
    if leftLand ~= rightLand then return leftLand < rightLand and -1 or 1 end
    return 0
end

local function compareCycleTie(left, right)
    local compared = compareCycleField(left, right)
    if compared ~= 0 then return compared < 0 end
    local leftStart = left.cycle.startMissionTime or 0
    local rightStart = right.cycle.startMissionTime or 0
    if leftStart ~= rightStart then return leftStart < rightStart end
    return tostring(left.cycle.id) < tostring(right.cycle.id)
end

local function cycleTableSortValue(row, sortBy)
    if sortBy == "field" then return row.cycle.fieldId end
    if sortBy == "crop" then
        return string.lower(tostring(row.cycle.fruitType or ""))
    end
    if sortBy == "state" then
        return ({open=1, closed=2, archived=3})[row.cycle.state]
    end
    if sortBy == "period" then return row.cycle.startMissionTime end
    if sortBy == "area" then return row.cycle.cycleAreaHa end
    if sortBy == "yieldPerHa" then return row.yieldLitresPerHa end
    if sortBy == "valuePerHa" then return row.valuePerHa end
    if sortBy == "costPerHa" then return row.costPerHa end
    if sortBy == "marginPerHa" then return row.marginPerHa end
    if sortBy == "quality" then
        return ({Complete=1, Partial=2, Unsupported=3})[row.qualityClass]
    end
    return nil
end

local function sortCycleTableRows(rows, sortBy, descending, grouped)
    table.sort(rows, function(left, right)
        if grouped and left.cycle.landKey ~= right.cycle.landKey then
            return compareCycleField(left, right) < 0
        end
        local leftValue = cycleTableSortValue(left, sortBy)
        local rightValue = cycleTableSortValue(right, sortBy)
        local leftAvailable = leftValue ~= nil
        local rightAvailable = rightValue ~= nil
        if leftAvailable ~= rightAvailable then return leftAvailable end
        if leftAvailable and leftValue ~= rightValue then
            if descending then return leftValue > rightValue end
            return leftValue < rightValue
        end
        return compareCycleTie(left, right)
    end)
end

local function facetArray(counts)
    local result = {}
    for value, count in pairs(counts) do
        result[#result + 1] = {value=value, count=count}
    end
    table.sort(result, function(left, right)
        return tostring(left.value) < tostring(right.value)
    end)
    return result
end

function ReportService.new(ledger)
    if type(ledger) ~= "table"
        or type(ledger.listCycles) ~= "function"
        or type(ledger.queryCycle) ~= "function"
        or type(ledger.getAlias) ~= "function" then
        return nil, "invalidLedger"
    end
    local constants, reason = dependencies()
    if constants == nil then return nil, reason end
    return setmetatable({ledger=ledger, snapshotByCycle={live={}, canonical={}},
        summaryByCycle={}, detailByCycle={}, cycleTableRowsByCycle={},
        cycleTableOrderCache={}, cycleTableRevision=nil}, ReportService)
end

function ReportService:getRevision(includeLive)
    if includeLive == false
        and type(self.ledger.getCanonicalReportRevision) == "function" then
        return self.ledger:getCanonicalReportRevision()
    end
    if type(self.ledger.getReportRevision) ~= "function" then return 0 end
    return self.ledger:getReportRevision()
end

function ReportService:getCycleRevision(cycleId, includeLive)
    if includeLive == false
        and type(self.ledger.getCanonicalCycleRevision) == "function" then
        return self.ledger:getCanonicalCycleRevision(cycleId)
    end
    if type(self.ledger.getCycleRevision) ~= "function" then
        return self:getRevision(includeLive)
    end
    return self.ledger:getCycleRevision(cycleId)
end

function ReportService:_snapshot(cycleId, includeLive)
    includeLive = includeLive ~= false
    local revision, reason = self:getCycleRevision(cycleId, includeLive)
    local cache = self.snapshotByCycle[includeLive and "live" or "canonical"]
    if revision == nil then
        cache[cycleId] = nil
        self.summaryByCycle[cycleId] = nil
        self.detailByCycle[cycleId] = nil
        return nil, reason
    end
    local cached = cache[cycleId]
    if cached ~= nil and cached.revision == revision then
        return detached(cached.query)
    end
    local query
    query, reason = self.ledger:queryCycle(cycleId, {
        includeExcluded=false, includeLive=includeLive, recordLimit=0})
    if query == nil then return nil, reason end
    cache[cycleId] = {revision=revision, query=detached(query)}
    return query
end

function ReportService:listCycles(options)
    local constants, accounting = dependencies()
    if constants == nil then return nil, accounting end
    options = options or {}
    if type(options) ~= "table" or getmetatable(options) ~= nil
        or (rawget(options, "includeLive") ~= nil
            and type(rawget(options, "includeLive")) ~= "boolean") then
        return nil, "invalidListOptions"
    end
    local includeLive = rawget(options, "includeLive") ~= false
    local filters = {}
    for key, value in pairs(options) do
        if key ~= "includeLive" then filters[key] = value end
    end
    local listed, reason = self.ledger:listCycles(filters)
    if listed == nil then return nil, reason end
    local rows = {}
    local previousLandKey = nil
    for index, cycle in ipairs(listed.cycles or {}) do
        local query
        query, reason = self:_snapshot(cycle.id, includeLive)
        if query == nil then return nil, reason end
        local attached
        attached, reason = attachCycleAlias(self.ledger, query.cycle)
        if attached == nil then return nil, reason end
        local row = summaryFromQuery(constants, accounting, query)
        if filters.fieldGrouped == true then
            row.fieldGroupStart = previousLandKey ~= cycle.landKey
            row.fieldGroupContinuesFromPreviousPage =
                index == 1
                and listed.page.fieldGroupContinuesFromPreviousPage == true
            previousLandKey = cycle.landKey
        end
        rows[#rows + 1] = row
    end
    return {rows = rows, page = copyMap(listed.page)}
end

-- Full-table presentation query. It is detached, read-only, and deliberately
-- separate from canonical ledger ordering and CSV export ordering.
function ReportService:listCycleTable(options)
    local constants, accounting, serialization = dependencies()
    if constants == nil then return nil, accounting end
    local accepted = knownOptions(options, CYCLE_TABLE_OPTION_KEYS)
    if accepted == nil then return nil, "invalidCycleTableOptions" end

    local scope = accepted.scope or "all"
    if scope ~= "current" and scope ~= "history" and scope ~= "all" then
        return nil, "invalidCycleTableOptions"
    end
    if accepted.state ~= nil and accepted.states ~= nil
        or scope ~= "all"
            and (accepted.state ~= nil or accepted.states ~= nil) then
        return nil, "invalidCycleTableOptions"
    end
    if accepted.groupByField ~= nil
        and type(accepted.groupByField) ~= "boolean"
        or accepted.includeLive ~= nil
            and type(accepted.includeLive) ~= "boolean"
        or accepted.descending ~= nil
            and type(accepted.descending) ~= "boolean" then
        return nil, "invalidCycleTableOptions"
    end
    local sortBy = accepted.sortBy or "period"
    if CYCLE_TABLE_SORT_KEYS[sortBy] ~= true then
        return nil, "invalidCycleTableOptions"
    end
    local descending = accepted.descending
    if descending == nil then descending = sortBy ~= "field"
        and sortBy ~= "crop" and sortBy ~= "state"
        and sortBy ~= "quality" end
    local offset = boundedInteger(
        accepted.offset or 0, 0, constants.LIMITS.maxRecords)
    local limit = boundedInteger(
        accepted.limit == nil and constants.LIMITS.maxQueryRows
            or accepted.limit,
        0,
        constants.LIMITS.maxQueryRows)
    if offset == nil or limit == nil then
        return nil, "invalidCycleTableOptions"
    end
    if accepted.crop ~= nil
        and (type(accepted.crop) ~= "string" or #accepted.crop > 64)
        or accepted.quality ~= nil
            and constants.QUALITY_CLASS_SET[accepted.quality] ~= true then
        return nil, "invalidCycleTableOptions"
    end
    local search = normalizedText(accepted.search)
    if search == false then return nil, "invalidCycleTableOptions" end
    local switches, reason = cycleTableScenarioOptions(accepted.scenario)
    if switches == nil then return nil, reason end
    local includeLive = accepted.includeLive ~= false
    local grouped = accepted.groupByField == true
    local revision = self:getRevision(includeLive)
    if revision ~= self.cycleTableRevision then
        self.cycleTableRevision = revision
        self.cycleTableOrderCache = {}
    end

    local stateKey = ""
    if accepted.state ~= nil then
        if constants.CYCLE_STATE_SET[accepted.state] ~= true then
            return nil, "invalidCycleTableOptions"
        end
        stateKey = accepted.state
    elseif accepted.states ~= nil then
        if type(accepted.states) ~= "table"
            or getmetatable(accepted.states) ~= nil
            or #accepted.states == 0 or #accepted.states > 3 then
            return nil, "invalidCycleTableOptions"
        end
        local seen, values = {}, {}
        for _, state in ipairs(accepted.states) do
            if constants.CYCLE_STATE_SET[state] ~= true or seen[state] then
                return nil, "invalidCycleTableOptions"
            end
            seen[state] = true
            values[#values + 1] = state
        end
        table.sort(values)
        stateKey = table.concat(values, ",")
    end
    local scenarioKey = cycleTableScenarioKey(switches)
    local orderKey = table.concat({
        tostring(accepted.farmId or ""),
        scope,
        stateKey,
        tostring(accepted.crop or ""),
        tostring(accepted.quality or ""),
        tostring(search or ""),
        sortBy,
        descending and "1" or "0",
        grouped and "1" or "0",
        includeLive and "1" or "0",
        scenarioKey
    }, "|")
    local cached = self.cycleTableOrderCache[orderKey]
    if cached == nil then
        local listOptions = {
            farmId=accepted.farmId,
            newestFirst=true,
            offset=0,
            limit=constants.LIMITS.maxQueryRows
        }
        if scope == "current" then
            listOptions.state = constants.CYCLE_STATE.Open
        elseif scope == "history" then
            listOptions.states = {
                constants.CYCLE_STATE.Closed,
                constants.CYCLE_STATE.Archived
            }
        elseif accepted.state ~= nil then
            listOptions.state = accepted.state
        elseif accepted.states ~= nil then
            listOptions.states = copyArray(accepted.states)
        end

        local sourceCycles, sourceTotal = {}, 0
        repeat
            local listed
            listed, reason = self.ledger:listCycles(listOptions)
            if listed == nil then return nil, reason end
            sourceTotal = listed.page.total or sourceTotal
            for _, cycle in ipairs(listed.cycles or {}) do
                sourceCycles[#sourceCycles + 1] = cycle
            end
            listOptions.offset = listed.page.nextOffset
        until listOptions.offset == nil

        local rows = {}
        local facetCounts = {crops={}, qualities={}, states={}}
        for _, cycle in ipairs(sourceCycles) do
            local cycleRevision
            cycleRevision, reason = self:getCycleRevision(cycle.id, includeLive)
            if cycleRevision == nil then return nil, reason end
            local rowKey = scenarioKey
                .. "|" .. (includeLive and "1" or "0")
            local entries = self.cycleTableRowsByCycle[cycle.id]
            local entry = entries ~= nil and entries[rowKey] or nil
            local row = entry ~= nil
                and entry.revision == cycleRevision
                and detached(entry.row) or nil
            if row == nil then
                local query
                query, reason = self:_snapshot(cycle.id, includeLive)
                if query == nil then return nil, reason end
                local attached
                attached, reason = attachCycleAlias(self.ledger, query.cycle)
                if attached == nil then return nil, reason end
                row, reason = cycleTableRow(
                    constants, accounting, serialization, query, switches)
                if row == nil then return nil, reason end
                entries = entries or {}
                entries[rowKey] = {
                    revision=cycleRevision,
                    row=detached(row)
                }
                self.cycleTableRowsByCycle[cycle.id] = entries
            end
            local crop = tostring(row.cycle.fruitType or "")
            facetCounts.crops[crop] = (facetCounts.crops[crop] or 0) + 1
            facetCounts.qualities[row.qualityClass] =
                (facetCounts.qualities[row.qualityClass] or 0) + 1
            facetCounts.states[row.cycle.state] =
                (facetCounts.states[row.cycle.state] or 0) + 1
            if (accepted.crop == nil or crop == accepted.crop)
                and (accepted.quality == nil
                    or row.qualityClass == accepted.quality)
                and (search == nil
                    or string.find(cycleSearchText(row), search, 1, true)
                        ~= nil) then
                rows[#rows + 1] = row
            end
        end
        sortCycleTableRows(rows, sortBy, descending, grouped)

        local sections, sectionByLand = {}, {}
        for index, row in ipairs(rows) do
            row.absoluteIndex = index
            if grouped then
                local landKey = row.cycle.landKey
                local section = sectionByLand[landKey]
                if section == nil then
                    section = {
                        index=#sections + 1,
                        landKey=landKey,
                        cycle=row.cycle,
                        offset=index - 1,
                        count=0
                    }
                    sections[#sections + 1] = section
                    sectionByLand[landKey] = section
                end
                section.count = section.count + 1
                row.sectionIndex = section.index
                row.indexInSection = section.count
                row.fieldGroupStart = section.count == 1
            else
                row.sectionIndex = 1
                row.indexInSection = index
            end
        end
        if not grouped then
            sections[1] = {index=1, offset=0, count=#rows}
        end
        cached = {
            rows=rows,
            sections=sections,
            sourceTotal=sourceTotal,
            facets={
                crops=facetArray(facetCounts.crops),
                qualities=facetArray(facetCounts.qualities),
                states=facetArray(facetCounts.states)
            }
        }
        self.cycleTableOrderCache[orderKey] = cached
    end

    local pageRows = {}
    local last = math.min(#cached.rows, offset + limit)
    if limit > 0 then
        for index = offset + 1, last do
            pageRows[#pageRows + 1] = detached(cached.rows[index])
        end
    end
    local nextOffset = nil
    if limit > 0 and offset + #pageRows < #cached.rows then
        nextOffset = offset + #pageRows
    end
    return {
        rows=pageRows,
        sections=detached(cached.sections),
        facets=detached(cached.facets),
        sort={sortBy=sortBy, descending=descending},
        scope=scope,
        groupByField=grouped,
        scenario=switches,
        page={
            offset=offset,
            limit=limit,
            total=#cached.rows,
            sourceTotal=cached.sourceTotal,
            nextOffset=nextOffset
        }
    }
end

function ReportService:cycleDetail(cycleId, options)
    local constants, accounting = dependencies()
    if constants == nil then return nil, accounting end
    local accepted = knownOptions(options, DETAIL_OPTION_KEYS)
    if accepted == nil then return nil, "invalidDetailOptions" end
    local queryOptions = {
        includeExcluded = accepted.includeExcluded,
        includeLive = accepted.includeLive ~= false,
        recordLimit = accepted.recordLimit,
        recordOffset = accepted.recordOffset
    }
    local revision, revisionReason = self:getCycleRevision(
        cycleId, queryOptions.includeLive)
    if revision == nil then return nil, revisionReason end
    local key = tostring(queryOptions.includeLive) .. "|"
        .. tostring(queryOptions.includeExcluded) .. "|"
        .. tostring(queryOptions.recordOffset) .. "|"
        .. tostring(queryOptions.recordLimit)
    local cached = self.detailByCycle[cycleId]
    if cached ~= nil and cached.revision == revision and cached.key == key then
        return detached(cached.result)
    end
    local query, reason = self.ledger:queryCycle(cycleId, queryOptions)
    if query == nil then return nil, reason end
    local attached
    attached, reason = attachCycleAlias(self.ledger, query.cycle)
    if attached == nil then return nil, reason end
    local sections = {
        operations = {}, inputs = {}, harvest = {}, machinery = {},
        labour = {}, allocations = {}, valuations = {}, other = {}
    }
    for _, record in ipairs(query.records or {}) do
        local name = SECTION_BY_RECORD_TYPE[record.recordType] or "other"
        sections[name][#sections[name] + 1] = record
    end
    local result = summaryFromQuery(constants, accounting, query)
    result.records = copyArray(query.records)
    result.recordPage = copyMap(query.recordPage)
    result.sections = sections
    result.corrections = copyArray(query.corrections)
    result.exclusions = copyArray(query.exclusions)
    self.detailByCycle[cycleId] = {
        revision=revision, key=key, result=detached(result)}
    return detached(result)
end

function ReportService:scenario(cycleId, options)
    local constants, accounting, serialization = dependencies()
    if constants == nil then return nil, accounting end
    local query, reason = self:_snapshot(cycleId, true)
    if query == nil then return nil, reason end
    return scenarioFromQuery(constants, accounting, serialization, query, options)
end

-- Compare one selected crop across the current farm's bounded history window.
-- Every metric is derived from queryCycle DTOs; no independent totals are kept.
function ReportService:comparison(cycleId, options)
    local constants, accounting, serialization = dependencies()
    if constants == nil then return nil, accounting end
    local accepted = knownOptions(options, COMPARISON_OPTION_KEYS)
    if accepted == nil then return nil, "invalidComparisonOptions" end
    local sortBy = accepted.sortBy or "marginPerHa"
    if COMPARISON_SORT_KEYS[sortBy] ~= true then
        return nil, "invalidComparisonOptions"
    end
    local descending = accepted.descending
    if descending == nil then
        descending = sortBy ~= "field"
    elseif type(descending) ~= "boolean" then
        return nil, "invalidComparisonOptions"
    end
    local offset = accepted.offset or 0
    local limit = accepted.limit or 6
    offset = boundedInteger(offset, 0, constants.LIMITS.maxRecords)
    limit = boundedInteger(limit, 0, constants.LIMITS.maxQueryRows)
    if offset == nil or limit == nil then
        return nil, "invalidComparisonOptions"
    end

    local selectedQuery, reason = self:_snapshot(cycleId, true)
    if selectedQuery == nil then return nil, reason end
    local attached
    attached, reason = attachCycleAlias(self.ledger, selectedQuery.cycle)
    if attached == nil then return nil, reason end
    local selectedCycle = selectedQuery.cycle
    local listed
    listed, reason = self.ledger:listCycles({
        farmId = selectedCycle.farmId,
        newestFirst = true,
        offset = 0,
        limit = constants.LIMITS.maxQueryRows
    })
    if listed == nil then return nil, reason end

    local sourceCycles, selectedFound = {}, false
    for _, cycle in ipairs(listed.cycles or {}) do
        if cycle.fruitType == selectedCycle.fruitType then
            sourceCycles[#sourceCycles + 1] = cycle
            if cycle.id == selectedCycle.id then selectedFound = true end
        end
    end
    if not selectedFound then
        if #sourceCycles >= constants.LIMITS.maxQueryRows then
            sourceCycles[#sourceCycles] = nil
        end
        sourceCycles[#sourceCycles + 1] = selectedCycle
    end

    local rows, selectedRow = {}, nil
    for _, cycle in ipairs(sourceCycles) do
        local query = cycle.id == selectedCycle.id and selectedQuery or nil
        if query == nil then
            query, reason = self:_snapshot(cycle.id, true)
            if query == nil then return nil, reason end
            attached, reason = attachCycleAlias(self.ledger, query.cycle)
            if attached == nil then return nil, reason end
        end
        local row
        row, reason = comparisonRow(constants, accounting, serialization, query)
        if row == nil then return nil, reason end
        row.selected = cycle.id == selectedCycle.id
        rows[#rows + 1] = row
        if row.selected then selectedRow = row end
    end
    local averages, averageCounts = meanMetrics(rows)
    sortComparisonRows(rows, sortBy, descending)

    local pageRows = {}
    local last = math.min(#rows, offset + limit)
    if limit > 0 then
        for index = offset + 1, last do pageRows[#pageRows + 1] = rows[index] end
    end
    local nextOffset = nil
    if limit > 0 and offset + #pageRows < #rows then
        nextOffset = offset + #pageRows
    end
    return {
        selected = selectedRow,
        rows = pageRows,
        averages = averages,
        averageCounts = averageCounts,
        scope = {
            farmId = selectedCycle.farmId,
            fruitType = selectedCycle.fruitType,
            comparableCount = #rows,
            sourceCycleCount = listed.page.total or #listed.cycles,
            windowLimit = constants.LIMITS.maxQueryRows,
            truncated = (listed.page.total or 0) > constants.LIMITS.maxQueryRows
        },
        sort = {sortBy = sortBy, descending = descending},
        page = {
            offset = offset,
            limit = limit,
            total = #rows,
            nextOffset = nextOffset
        }
    }
end

FieldProfitabilityLedger.Services.ReportService = ReportService
return ReportService
