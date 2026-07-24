FieldProfitabilityLedger = FieldProfitabilityLedger or {}
FieldProfitabilityLedger.Core = FieldProfitabilityLedger.Core or {}

local Constants = {}

Constants.SCHEMA_VERSION = 1
Constants.STOP_GRACE_MS = 200
Constants.DEFAULT_EPSILON = 0.000001

Constants.ACCOUNTING_CLASS = {
    Observed = "Observed",
    Direct = "Direct",
    Valued = "Valued",
    Allocated = "Allocated",
    Estimated = "Estimated"
}

Constants.QUALITY_CLASS = {
    Complete = "Complete",
    Partial = "Partial",
    Unsupported = "Unsupported"
}

Constants.CONFIDENCE = {
    High = "High",
    Medium = "Medium",
    Low = "Low",
    NotApplicable = "NotApplicable"
}

Constants.CYCLE_STATE = {
    Open = "open",
    Closed = "closed",
    Archived = "archived"
}

Constants.SESSION_STATE = {
    Open = "open",
    Closed = "closed"
}

Constants.RECORD_TYPE = {
    Operation = "operation",
    Input = "input",
    Harvest = "harvest",
    Machinery = "machinery",
    Labour = "labour",
    Allocation = "allocation",
    Valuation = "valuation",
    Summary = "summary"
}

Constants.UNIT = {
    Litres = "litres",
    Hectares = "hectares",
    Milliseconds = "milliseconds",
    Money = "money",
    Ratio = "ratio"
}

-- Canonical non-operation categories shared by adapters, queries, GUI, and
-- CSV. Operation-area categories use Constants.OPERATION tokens directly.
Constants.CATEGORY = {
    seed = "seed",
    fertilizer = "fertilizer",
    lime = "lime",
    herbicide = "herbicide",
    manure = "manure",
    slurry = "slurry",
    digestate = "digestate",
    fuel = "fuel",
    def = "def",
    harvest = "harvest",
    workingTime = "workingTime",
    aiLabourTime = "aiLabourTime",
    playerLabourTime = "playerLabourTime",
    wearDelta = "wearDelta",
    directObservedCost = "directObservedCost",
    inputReplacementValue = "inputReplacementValue",
    fuelReplacementValue = "fuelReplacementValue",
    defReplacementValue = "defReplacementValue",
    estimatedHarvestValue = "estimatedHarvestValue",
    leaseAllocation = "leaseAllocation",
    repairLiability = "repairLiability",
    aiLabourAllocation = "aiLabourAllocation",
    playerLabourAllocation = "playerLabourAllocation",
    ownershipAllocation = "ownershipAllocation"
}

Constants.DIRECTION = {
    Expense = "expense",
    IncomeValue = "incomeValue"
}

Constants.RETENTION_MODE = {
    All = "all",
    GameYears = "gameYears"
}

Constants.OPERATION = {
    plowing = true,
    subsoiling = true,
    cultivating = true,
    discHarrowing = true,
    powerHarrowing = true,
    mulching = true,
    stonePicking = true,
    seedingPlanting = true,
    rolling = true,
    mechanicalWeeding = true,
    fertilizer = true,
    lime = true,
    herbicide = true,
    manure = true,
    slurry = true,
    digestate = true,
    ordinaryArableHarvest = true
}

Constants.LIMITS = {
    idBytes = 64,
    tokenBytes = 64,
    textBytes = 128,
    maxPhysical = 1000000000,
    maxRatio = 1,
    maxAreaHa = 100000,
    maxWorldCoordinate = 1000000,
    maxPolygonPoints = 4096,
    maxGeometryEpsilon = 1,
    maxMoney = 1000000000000,
    maxUnitPrice = 1000000,
    maxDurationMs = 3153600000000,
    maxMissionTime = 3153600000000,
    maxPeriod = 12,
    maxYear = 1000000,
    maxReasons = 32,
    maxReferences = 128,
    maxBoundaryCandidates = 16,
    maxComponents = 512,
    maxQueryRows = 100,
    maxLoadDiagnostics = 128,
    maxNeutralDepth = 32,
    maxNeutralItems = 1000000,
    maxLedgerNeutralItems = 1000000,
    maxEncodedBytes = 32 * 1024 * 1024,
    maxRecords = 1000000,
    maxRetentionYears = 1000,
    maxIdentifier = 9007199254740991
}

local function valueSet(values)
    local result = {}
    for _, value in pairs(values) do
        result[value] = true
    end
    return result
end

Constants.ACCOUNTING_CLASS_SET = valueSet(Constants.ACCOUNTING_CLASS)
Constants.QUALITY_CLASS_SET = valueSet(Constants.QUALITY_CLASS)
Constants.CYCLE_STATE_SET = valueSet(Constants.CYCLE_STATE)
Constants.RECORD_TYPE_SET = valueSet(Constants.RECORD_TYPE)
Constants.CONFIDENCE_SET = valueSet(Constants.CONFIDENCE)
Constants.UNIT_SET = valueSet(Constants.UNIT)
Constants.CATEGORY_SET = valueSet(Constants.CATEGORY)
Constants.DIRECTION_SET = valueSet(Constants.DIRECTION)
Constants.RETENTION_MODE_SET = valueSet(Constants.RETENTION_MODE)

Constants.UNIT_LIMIT = {
    [Constants.UNIT.Litres] = Constants.LIMITS.maxPhysical,
    [Constants.UNIT.Hectares] = Constants.LIMITS.maxAreaHa,
    [Constants.UNIT.Milliseconds] = Constants.LIMITS.maxDurationMs,
    [Constants.UNIT.Money] = Constants.LIMITS.maxMoney,
    [Constants.UNIT.Ratio] = Constants.LIMITS.maxRatio
}

FieldProfitabilityLedger.Core.Constants = Constants

return Constants
