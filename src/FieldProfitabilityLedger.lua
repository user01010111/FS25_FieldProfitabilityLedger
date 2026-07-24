-- FieldProfitabilityLedger single-player runtime entry point.

local namespace = rawget(_G, "FieldProfitabilityLedger")
if type(namespace) ~= "table" then
    error("FieldProfitabilityLedger load error: runtime namespace is unavailable", 0)
end
if rawget(namespace, "RuntimeManifest") ~= nil then
    error("FieldProfitabilityLedger load error: runtime manifest namespace collision", 0)
end

local expectedModules = {
    { "Core", "Constants", "src/core/Constants.lua" },
    { "Core", "Validation", "src/core/Validation.lua" },
    { "Core", "Identifiers", "src/core/Identifiers.lua" },
    { "Core", "Accounting", "src/core/Accounting.lua" },
    { "Core", "Serialization", "src/core/Serialization.lua" },
    { "Core", "Migrations", "src/core/Migrations.lua" },
    { "Core", "ExactSum", "src/core/ExactSum.lua" },
    { "Core", "Ledger", "src/core/Ledger.lua" },
    { "Core", "Retention", "src/core/Retention.lua" },
    { "Core", "Geometry", "src/core/Geometry.lua" },
    { "Core", "FieldAttribution", "src/core/FieldAttribution.lua" },
    { "Core", "OperationCoordinator", "src/core/OperationCoordinator.lua" },
    { "Persistence", "LedgerStore", "src/persistence/LedgerStore.lua" },
    { "Persistence", "SavegameFilePort", "src/persistence/SavegameFilePort.lua" },
    { "Persistence", "SettingsFilePort", "src/persistence/SettingsFilePort.lua" },
    { "Persistence", "ExportFilePort", "src/persistence/ExportFilePort.lua" },
    { "Services", "ReportService", "src/services/ReportService.lua" },
    { "Services", "ClientSettings", "src/services/ClientSettings.lua" },
    { "Services", "LedgerCommands", "src/services/LedgerCommands.lua" },
    { "Export", "CsvEncoder", "src/export/CsvEncoder.lua" },
    { "Export", "ExportService", "src/export/ExportService.lua" },
    { "Adapters", "ApplicationObserver", "src/adapters/ApplicationObserver.lua" },
    { "Adapters", "HarvestObserver", "src/adapters/HarvestObserver.lua" },
    { "Adapters", "MachineryMeter", "src/adapters/MachineryMeter.lua" },
    { "Adapters", "WorkAreaAdapter", "src/adapters/WorkAreaAdapter.lua" },
    { "Runtime", "ApplicationRuntimeAdapter", "src/runtime/ApplicationRuntimeAdapter.lua" },
    { "Runtime", "HarvestRuntimeAdapter", "src/runtime/HarvestRuntimeAdapter.lua" },
    { "Runtime", "MachineryRuntimeAdapter", "src/runtime/MachineryRuntimeAdapter.lua" },
    { "Runtime", "EconomicsRuntimeAdapter", "src/runtime/EconomicsRuntimeAdapter.lua" },
    { "Runtime", "Register", "src/runtime/Register.lua" },
    { "Gui", "LedgerFrame", "src/gui/LedgerFrame.lua" },
    { "Gui", "GuiController", "src/gui/GuiController.lua" },
    { "Runtime", "SinglePlayerRuntime", "src/runtime/SinglePlayerRuntime.lua" }
}

local sourceOrder = {}
for index, expected in ipairs(expectedModules) do
    local namespaceName, moduleName, sourcePath = expected[1], expected[2], expected[3]
    local group = rawget(namespace, namespaceName)
    if type(group) ~= "table" or type(rawget(group, moduleName)) ~= "table" then
        error(string.format(
            "FieldProfitabilityLedger load error: expected module '%s.%s' after '%s'",
            namespaceName, moduleName, sourcePath
        ), 0)
    end
    sourceOrder[index] = sourcePath
end
sourceOrder[#sourceOrder + 1] = "src/FieldProfitabilityLedger.lua"

local register = namespace.Runtime.Register
local registered, registerReason = register.install()
if registered == nil then
    error("FieldProfitabilityLedger load error: specialization registration failed: "
        .. tostring(registerReason), 0)
end

local runtime = namespace.Runtime.SinglePlayerRuntime
local installed, installReason = runtime.install()
if installed == nil then
    error("FieldProfitabilityLedger load error: mission listener installation failed: "
        .. tostring(installReason), 0)
end

local manifestValues = {
    moduleId = "FS25_FieldProfitabilityLedger",
    version = "0.1.0.0",
    singlePlayerOnly = true,
    sourceCount = #sourceOrder,
    sourceOrder = table.concat(sourceOrder, "\n")
}
local runtimeManifest = {}
setmetatable(runtimeManifest, {
    __index = manifestValues,
    __newindex = function()
        error("FieldProfitabilityLedger runtime manifest is immutable", 2)
    end,
    __metatable = "FieldProfitabilityLedger runtime manifest"
})
rawset(namespace, "RuntimeManifest", runtimeManifest)

return runtimeManifest
