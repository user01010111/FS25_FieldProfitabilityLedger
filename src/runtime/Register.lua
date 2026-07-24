-- Install the late collector/vehicle bridge specialization before vehicle
-- type validation. The specialization itself is inert until activation.

FieldProfitabilityLedger = FieldProfitabilityLedger or {}
FieldProfitabilityLedger.Runtime = FieldProfitabilityLedger.Runtime or {}

local Register = {installed = false, applicationReason = nil,
    harvestReason = nil, machineryReason = nil}
local collectorQualifiedName = nil

local function addToWorkAreaTypes(manager)
    if type(manager) ~= "table" or rawget(manager, "typeName") ~= "vehicle"
        or type(g_vehicleTypeManager) ~= "table"
        or type(g_vehicleTypeManager.getTypes) ~= "function" then
        return
    end
    local types = g_vehicleTypeManager:getTypes()
    for typeName, typeEntry in pairs(types) do
        local specializations = type(typeEntry) == "table"
            and typeEntry.specializations or nil
        local supported = type(specializations) == "table" and (
            (type(_G.WorkArea) == "table"
                and SpecializationUtil.hasSpecialization(WorkArea, specializations))
            or (type(_G.Motorized) == "table"
                and SpecializationUtil.hasSpecialization(Motorized, specializations))
            or (type(_G.Wearable) == "table"
                and SpecializationUtil.hasSpecialization(Wearable, specializations))
            or (type(_G.FillUnit) == "table"
                and SpecializationUtil.hasSpecialization(FillUnit, specializations)))
        if supported then
            g_vehicleTypeManager:addSpecialization(typeName, collectorQualifiedName)
        end
    end
end

function Register.install()
    if Register.installed then return true, false end
    if type(g_specializationManager) ~= "table"
        or type(g_specializationManager.addSpecialization) ~= "function"
        or type(TypeManager) ~= "table"
        or type(TypeManager.validateTypes) ~= "function"
        or type(Utils) ~= "table"
        or type(Utils.prependedFunction) ~= "function"
        or type(g_currentModName) ~= "string"
        or type(g_currentModDirectory) ~= "string" then
        return nil, "registrationRuntimeUnavailable"
    end
    local application = FieldProfitabilityLedger.Runtime.ApplicationRuntimeAdapter
    if type(application) == "table"
        and type(application.installClassWrappers) == "function" then
        local installed, reason = application.installClassWrappers()
        if installed == nil then Register.applicationReason = reason end
    else
        Register.applicationReason = "applicationRuntimeUnavailable"
    end
    local harvest = FieldProfitabilityLedger.Runtime.HarvestRuntimeAdapter
    if type(harvest) == "table"
        and type(harvest.installClassWrapper) == "function" then
        local installed, reason = harvest.installClassWrapper()
        if installed == nil then Register.harvestReason = reason end
    else
        Register.harvestReason = "harvestRuntimeUnavailable"
    end
    local machinery = FieldProfitabilityLedger.Runtime.MachineryRuntimeAdapter
    if type(machinery) == "table"
        and type(machinery.installClassWrapper) == "function" then
        local machineryInstalled, reason = machinery.installClassWrapper()
        if machineryInstalled == nil then Register.machineryReason = reason end
    else
        Register.machineryReason = "machineryRuntimeUnavailable"
    end
    g_specializationManager:addSpecialization(
        "fieldProfitabilityLedgerCollector",
        "FieldProfitabilityLedgerCollector",
        g_currentModDirectory .. "src/runtime/WorkAreaCollector.lua",
        nil
    )
    collectorQualifiedName = g_currentModName
        .. ".fieldProfitabilityLedgerCollector"
    TypeManager.validateTypes = Utils.prependedFunction(
        TypeManager.validateTypes, addToWorkAreaTypes)
    Register.installed = true
    return true, true
end

function Register.getStatus()
    return {
        installed = Register.installed,
        applicationReason = Register.applicationReason,
        harvestReason = Register.harvestReason,
        machineryReason = Register.machineryReason
    }
end

FieldProfitabilityLedger.Runtime.Register = Register
return Register
