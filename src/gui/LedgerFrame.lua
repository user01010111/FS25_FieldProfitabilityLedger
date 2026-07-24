-- Native FS25 presentation for the detached Field Profitability Ledger reports.

FieldProfitabilityLedger = FieldProfitabilityLedger or {}
FieldProfitabilityLedger.Gui = FieldProfitabilityLedger.Gui or {}

FieldProfitabilityLedgerFrame = FieldProfitabilityLedgerFrame or {}

local BaseFrame = _G.TabbedMenuFrameElement
local classFunction = _G.Class
local FrameMt = nil
if type(BaseFrame) == "table" and type(classFunction) == "function" then
    FrameMt = classFunction(FieldProfitabilityLedgerFrame, BaseFrame)
end

local PAGE_SIZE = 100
local MAX_LEGACY_SELECTION = 100
local TAB_ORDER = {
    "cycles", "overview", "activity", "scenario", "comparison", "settings"
}
local TAB_TEXT_KEYS = {
    cycles="fpl_cycles",
    overview="fpl_overview",
    activity="fpl_activity",
    scenario="fpl_scenario",
    comparison="fpl_comparison",
    settings="fpl_settings"
}
local COMPARISON_METRICS = {
    "marginPerHa", "yieldPerHa", "costPerHa", "valuePerHa"
}

local function text(key)
    local i18n = _G.g_i18n
    if type(i18n) == "table" and type(i18n.getText) == "function" then
        local ok, value = pcall(i18n.getText, i18n, key)
        if ok and type(value) == "string" then return value end
    end
    return key
end

local function formatted(key, ...)
    local ok, value = pcall(string.format, text(key), ...)
    return ok and value or text(key)
end

local function finiteNumber(value)
    return type(value) == "number" and value == value
        and value ~= math.huge and value ~= -math.huge
end

local function setText(element, value)
    if type(element) == "table" and type(element.setText) == "function" then
        element:setText(value or "")
    end
end

local function setVisible(element, value)
    if type(element) == "table" and type(element.setVisible) == "function" then
        element:setVisible(value == true)
    end
end

local function setDisabled(element, value)
    if type(element) == "table" and type(element.setDisabled) == "function" then
        element:setDisabled(value == true)
    elseif type(element) == "table" then
        element.disabled = value == true
    end
end

local function setPosition(element, x, y)
    if type(element) == "table" and type(element.setPosition) == "function" then
        element:setPosition(x, y)
    end
end

local function setSize(element, width, height)
    if type(element) == "table" and type(element.setSize) == "function" then
        element:setSize(width, height)
    end
end

local function setImageColor(element, colour)
    if type(element) == "table" and type(element.setImageColor) == "function"
        and type(colour) == "table" then
        element:setImageColor(colour[1], colour[2], colour[3], colour[4])
    end
end

local function attribute(cell, name)
    if type(cell) ~= "table" then return nil end
    if type(cell.getAttribute) == "function" then
        local ok, value = pcall(cell.getAttribute, cell, name)
        if ok then return value end
    end
    return cell[name]
end

local function setCell(cell, name, value)
    setText(attribute(cell, name), value)
end

local function setCellColour(cell, name, colour)
    local element = attribute(cell, name)
    if type(element) ~= "table" or type(colour) ~= "table" then return end
    if type(element.setTextColor) == "function" then
        element:setTextColor(colour[1], colour[2], colour[3], colour[4])
    else
        element.textColor = colour
    end
end

local function displayNumber(value, decimals)
    if not finiteNumber(value) then return text("fpl_unavailable") end
    local i18n = _G.g_i18n
    if type(i18n) == "table" and type(i18n.formatNumber) == "function" then
        local ok, result = pcall(
            i18n.formatNumber, i18n, value, decimals or 2)
        if ok and type(result) == "string" then return result end
    end
    return string.format("%." .. tostring(decimals or 2) .. "f", value)
end

local function displayMoney(value)
    if not finiteNumber(value) then return text("fpl_unavailable") end
    local i18n = _G.g_i18n
    if type(i18n) == "table" and type(i18n.formatMoney) == "function" then
        local ok, result = pcall(
            i18n.formatMoney, i18n, value, 0, true, true)
        if ok and type(result) == "string" then return result end
    end
    return displayNumber(value, 0)
end

local function unitValue(amount, unit)
    if not finiteNumber(amount) then return text("fpl_unavailable") end
    if unit == "money" then return displayMoney(amount) end
    if unit == "milliseconds" then
        if amount < 60000 then
            return formatted("fpl_value_seconds",
                displayNumber(amount / 1000, amount < 10000 and 1 or 0))
        elseif amount < 3600000 then
            return formatted("fpl_value_minutes",
                displayNumber(amount / 60000, 1))
        end
        return formatted("fpl_value_hours",
            displayNumber(amount / 3600000, 2))
    elseif unit == "hectares" then
        if amount > 0 and amount < 0.01 then
            local squareMetres = amount * 10000
            if squareMetres < 10 then
                squareMetres =
                    math.floor(squareMetres * 10 + 0.500000001) / 10
            end
            return formatted("fpl_value_squareMetres",
                displayNumber(squareMetres, squareMetres < 10 and 1 or 0))
        end
        return formatted("fpl_value_hectares", displayNumber(amount, 2))
    elseif unit == "litres" then
        return formatted("fpl_value_litres", displayNumber(amount, 1))
    elseif unit == "ratio" then
        return formatted("fpl_value_percent", displayNumber(amount * 100, 1))
    end
    return displayNumber(amount, 2) .. " " .. tostring(unit or "")
end

FieldProfitabilityLedgerFrame.formatUnitValue = unitValue

local function moneyPerHa(value)
    return finiteNumber(value)
        and formatted("fpl_value_moneyPerHa", displayMoney(value))
        or text("fpl_unavailable")
end

local function yieldPerHa(value)
    return finiteNumber(value)
        and formatted("fpl_value_litresPerHa", displayNumber(value, 1))
        or text("fpl_unavailable")
end

local function cropLabel(cycle)
    local manager = _G.g_fruitTypeManager
    if type(manager) == "table"
        and type(manager.getFruitTypeByName) == "function"
        and type(cycle.fruitType) == "string" then
        local ok, descriptor = pcall(
            manager.getFruitTypeByName, manager, cycle.fruitType)
        if ok and type(descriptor) == "table"
            and type(descriptor.title) == "string" then
            return descriptor.title
        end
    end
    if cycle.fruitType == nil or cycle.fruitType == "unknown" then
        return text("fpl_unknownCrop")
    end
    return tostring(cycle.fruitType)
end

local function canonicalLandSearch(value)
    if type(value) ~= "string" then return value end
    local lowered = string.lower(value)
    local marker = "__fpl_land_search__"
    local function canonicalized(key, canonical)
        local template = string.lower(formatted(key, marker))
        local markerStart = string.find(template, marker, 1, true)
        if markerStart == nil then return nil end
        local prefix = string.sub(template, 1, markerStart - 1)
        local suffix = string.sub(template, markerStart + #marker)
        if string.sub(lowered, 1, #prefix) ~= prefix
            or (suffix ~= ""
                and string.sub(lowered, -#suffix) ~= suffix) then
            return nil
        end
        local last = #lowered - #suffix
        local identity = string.sub(lowered, #prefix + 1, last)
            :match("^%s*(.-)%s*$")
        if identity == nil or identity == "" then return nil end
        return canonical .. " " .. identity
    end
    return canonicalized("fpl_fieldNumber", "field")
        or canonicalized("fpl_parcelNumber", "parcel")
        or value
end

local function landLabel(cycle)
    local identity
    if cycle.fieldKind == "base" and cycle.fieldId ~= nil then
        identity = formatted("fpl_fieldNumber", cycle.fieldId)
    else
        identity = formatted("fpl_parcelNumber", cycle.farmlandId or 0)
    end
    if type(cycle.alias) == "string" and cycle.alias ~= "" then
        return formatted("fpl_landAlias", cycle.alias, identity)
    end
    return identity
end

local function missionTimeLabel(value)
    if not finiteNumber(value) or value < 0 then
        return text("fpl_unavailable")
    end
    local seconds = math.floor(value / 1000)
    return string.format("%d:%02d:%02d",
        math.floor(seconds / 3600),
        math.floor((seconds % 3600) / 60),
        seconds % 60)
end

local function cyclePeriod(cycle)
    return formatted("fpl_cyclePeriod",
        missionTimeLabel(cycle.startMissionTime),
        cycle.endMissionTime ~= nil
            and missionTimeLabel(cycle.endMissionTime)
            or text("fpl_now"))
end

local function categoryLabel(value)
    local key = "fpl_category_" .. tostring(value or "unknown")
    local label = text(key)
    return label ~= key and label or tostring(value or text("fpl_unknown"))
end

local function classLabel(value)
    local key = "fpl_class_" .. tostring(value or "Unsupported")
    local label = text(key)
    return label ~= key and label or tostring(value or text("fpl_unknown"))
end

local function qualityLabel(value)
    local key = "fpl_quality_" .. tostring(value or "Unsupported")
    local label = text(key)
    return label ~= key and label or tostring(value or text("fpl_unknown"))
end

local function recordTypeLabel(value)
    local key = "fpl_recordType_" .. tostring(value or "unknown")
    local label = text(key)
    return label ~= key and label or tostring(value or text("fpl_unknown"))
end

local function reasonLabel(value)
    local key = "fpl_reason_" .. tostring(value or "unknown")
    local label = text(key)
    return label ~= key and label or tostring(value or text("fpl_unknown"))
end

local function stateLabel(value)
    local key = "fpl_state_" .. tostring(value or "unknown")
    local label = text(key)
    return label ~= key and label or tostring(value or text("fpl_unknown"))
end

local function booleanLabel(value)
    return value and text("fpl_enabled") or text("fpl_disabled")
end

local function logFailure(context, reason)
    local logging = _G.Logging
    if type(logging) == "table" and type(logging.warning) == "function" then
        pcall(logging.warning,
            "[FieldProfitabilityLedger] GUI %s failed: %s",
            tostring(context or "action"), tostring(reason or "unknown"))
    end
end

local function failureMessage(key, context, reason)
    logFailure(context, reason)
    local token = tostring(reason or "unknown")
    local label
    if token == "cycleNotFound" or token == "recordNotFound"
        or token == "recordCycleMismatch" or token == "staleSelection"
        or token == "legacyClosureSelectionChanged"
        or token == "legacyClosureSelectionNotReviewed" then
        label = text("fpl_error_selectionUnavailable")
    elseif token == "openCycleRequired"
        or token == "invalidCycleTransition" then
        label = text("fpl_error_openCycleRequired")
    elseif context == "settings" then
        label = text("fpl_error_settingsSave")
    elseif context == "query" then
        label = text("fpl_error_reportUnavailable")
    elseif context == "export" then
        label = text("fpl_error_exportUnavailable")
    elseif string.sub(token, 1, 7) == "invalid" then
        label = text("fpl_error_invalidRequest")
    else
        label = text("fpl_error_actionUnavailable")
    end
    return formatted(key, label)
end

local function showTextInput(callback, target, defaultText, title, context)
    local dialog = _G.TextInputDialog
    if type(dialog) ~= "table" or type(dialog.show) ~= "function" then
        return nil, "textInputUnavailable"
    end
    local ok = pcall(dialog.show, callback, target, defaultText or "",
        title, nil, 128, text("fpl_ok"), context)
    return ok and true or nil, ok and nil or "textInputUnavailable"
end

local function reload(list)
    if type(list) == "table" and type(list.reloadData) == "function" then
        list:reloadData()
    end
end

local function focus(element)
    local manager = _G.FocusManager
    if type(manager) == "table" and type(manager.setFocus) == "function"
        and type(element) == "table" then
        pcall(manager.setFocus, element)
    end
end

local function setSelectedPath(list, section, index)
    if type(list) == "table" and type(list.setSelectedItem) == "function"
        and type(section) == "number" and type(index) == "number" then
        pcall(list.setSelectedItem, list, section, index, true, true)
    end
end

local function simpleValue(value, depth)
    if type(value) ~= "table" then return tostring(value or "") end
    depth = depth or 0
    if depth >= 2 then return "{...}" end
    local values = {}
    for key, item in pairs(value) do
        values[#values + 1] = tostring(key) .. "="
            .. simpleValue(item, depth + 1)
        if #values >= 12 then
            values[#values + 1] = "..."
            break
        end
    end
    table.sort(values)
    return table.concat(values, ", ")
end

local function parseDelta(value)
    if type(value) ~= "string" then return nil end
    value = value:match("^%s*(.-)%s*$"):gsub(",", ".")
    if value:match("^[+-]?%d+%.?%d*$") == nil
        and value:match("^[+-]?%.%d+$") == nil then return nil end
    local result = tonumber(value)
    if not finiteNumber(result) or result == 0 then return nil end
    return result
end

function FieldProfitabilityLedgerFrame.calculateChartGeometry(values, average)
    local minimum, maximum
    for _, value in ipairs(values or {}) do
        if finiteNumber(value) then
            minimum = minimum == nil and value or math.min(minimum, value)
            maximum = maximum == nil and value or math.max(maximum, value)
        end
    end
    if minimum == nil then
        return {minimum=0, maximum=0, zeroFraction=0,
            averageFraction=nil, bars={}}
    end
    minimum, maximum = math.min(minimum, 0), math.max(maximum, 0)
    local span = maximum - minimum
    local function fraction(value)
        if not finiteNumber(value) then return nil end
        if span == 0 then return 0 end
        return math.max(0, math.min(1, (value - minimum) / span))
    end
    local zero, bars = fraction(0) or 0, {}
    for index, value in ipairs(values or {}) do
        local endpoint = fraction(value)
        bars[index] = endpoint == nil
            and {available=false, start=zero, width=0, negative=false}
            or {available=true, start=math.min(zero, endpoint),
                width=math.abs(endpoint - zero), negative=value < 0}
    end
    return {minimum=minimum, maximum=maximum, zeroFraction=zero,
        averageFraction=fraction(average), bars=bars}
end

local function defaultSettings()
    return {
        schemaVersion=2,
        newestFirst=true,
        showExcluded=true,
        cycleSortBy="period",
        cycleSortDescending=true,
        includeDirect=true,
        includeInputs=true,
        includeFuel=true,
        includeDef=true,
        includeAllocated=true
    }
end

function FieldProfitabilityLedgerFrame.new(
        report, exporter, settings, commands, runtimeStatusProvider)
    if FrameMt == nil or type(BaseFrame.new) ~= "function" then
        return nil, "guiBaseUnavailable"
    end
    local self = BaseFrame.new(nil, FrameMt)
    self.name = "fplFieldProfitabilityLedgerPage"
    self.report = report
    self.exporter = exporter
    self.settingsService = settings
    self.commands = commands
    self.runtimeStatusProvider = runtimeStatusProvider
    self.settings = settings ~= nil and settings:get() or defaultSettings()
    self.currentView = "cycles"
    self.cycleScope = "current"
    self.cycleCrop = nil
    self.cycleQuality = nil
    self.cycleSearch = nil
    self.groupByField = false
    self.cycleTable = nil
    self.cycleSections = {}
    self.cycleRowsByAbsolute = {}
    self.cyclePathById = {}
    self.selectedCycleId = nil
    self.selectedRecordId = nil
    self.selectedRecordValue = nil
    self.selectedDetail = nil
    self.activityRowsByAbsolute = {}
    self.comparisonRows = {}
    self.comparisonSortBy = "marginPerHa"
    self.comparisonDescending = true
    self.comparisonMetric = "marginPerHa"
    self.legacyRows = {}
    self.legacySelected = {}
    self.legacySelectionOrder = {}
    self.lastRenderedRevision = nil
    self.refreshElapsedMs = 0
    self.isFrameOpen = false
    self.tabElements = {}
    local actions = _G.InputAction
    if type(actions) == "table" and type(self.setMenuButtonInfo) == "function" then
        self:setMenuButtonInfo({
            {inputAction=actions.MENU_BACK},
            {inputAction=actions.MENU_EXTRA_1,
                text=text("fpl_exportCycles"),
                callback=function() self:onExport() end},
            {inputAction=actions.MENU_EXTRA_2,
                text=text("fpl_exportAudit"),
                callback=function() self:onExportAudit() end}
        })
    end
    return self
end

function FieldProfitabilityLedgerFrame:setServices(
        report, exporter, settings, commands, runtimeStatusProvider)
    self.report = report
    self.exporter = exporter
    self.settingsService = settings
    self.commands = commands
    self.runtimeStatusProvider = runtimeStatusProvider
    self.settings = settings ~= nil and settings:get() or defaultSettings()
    self.selectedCycleId = nil
    self.selectedRecordId = nil
    self.selectedRecordValue = nil
    self.lastRenderedRevision = nil
    self:resetSessionFilters()
end

function FieldProfitabilityLedgerFrame:deactivate()
    self.report = nil
    self.exporter = nil
    self.settingsService = nil
    self.commands = nil
    self.runtimeStatusProvider = nil
    self.selectedCycleId = nil
    self.selectedRecordId = nil
    self.selectedRecordValue = nil
    self.isFrameOpen = false
    self.lastRenderedRevision = nil
end

function FieldProfitabilityLedgerFrame:onGuiSetupFinished()
    local resolver = rawget(FieldProfitabilityLedgerFrame, "superClass")
    local super = type(resolver) == "function"
        and resolver(FieldProfitabilityLedgerFrame) or nil
    if type(super) == "table"
        and type(super.onGuiSetupFinished) == "function" then
        super.onGuiSetupFinished(self)
    end
    for _, list in ipairs({
        self.cycleList, self.totalsList, self.activityList,
        self.comparisonList, self.legacyList
    }) do
        if type(list) == "table" then
            if type(list.setDataSource) == "function" then
                list:setDataSource(self)
            end
            if type(list.setDelegate) == "function" then
                list:setDelegate(self)
            end
        end
    end
    self:buildTabs()
    self:bindSortHeaders(self.cycleSortHeaders, true)
    self:bindSortHeaders(self.comparisonSortHeaders, false)
    self:updateFilterControls()
    self:applyView("cycles")
end

function FieldProfitabilityLedgerFrame:buildTabs()
    if type(self.selectorPrefab) ~= "table"
        or type(self.subCategoryBox) ~= "table"
        or type(self.subCategoryPaging) ~= "table" then return end
    if type(self.subCategoryPaging.setTexts) == "function" then
        self.subCategoryPaging:setTexts({})
    end
    self.tabElements = {}
    if type(self.selectorPrefab.unlinkElement) == "function" then
        self.selectorPrefab:unlinkElement()
    end
    local manager = _G.FocusManager
    if type(manager) == "table" and type(manager.removeElement) == "function" then
        pcall(manager.removeElement, self.selectorPrefab)
    end
    for index, name in ipairs(TAB_ORDER) do
        if type(self.subCategoryPaging) == "table"
            and type(self.subCategoryPaging.addText) == "function" then
            self.subCategoryPaging:addText(tostring(index))
        end
        local tab = type(self.selectorPrefab.clone) == "function"
            and self.selectorPrefab:clone(self.subCategoryBox) or nil
        self.tabElements[index] = tab
        if type(tab) == "table" then
            if type(manager) == "table"
                and type(manager.loadElementFromCustomValues) == "function" then
                pcall(manager.loadElementFromCustomValues, tab)
            end
            setText(tab, text(TAB_TEXT_KEYS[name]))
            local background = type(tab.getDescendantByName) == "function"
                and tab:getDescendantByName("background") or nil
            if type(background) == "table"
                and type(background.setSize) == "function"
                and type(tab.size) == "table" then
                background:setSize(tab.size[1], tab.size[2])
            end
            tab.onClickCallback = function() self:showView(name) end
        end
    end
    if type(self.subCategoryBox.invalidateLayout) == "function" then
        self.subCategoryBox:invalidateLayout()
    end
    if type(self.subCategoryPaging.setSize) == "function"
        and finiteNumber(self.subCategoryBox.maxFlowSize) then
        local scaledPixel = finiteNumber(_G.g_pixelSizeScaledX)
            and _G.g_pixelSizeScaledX or 0
        self.subCategoryPaging:setSize(
            self.subCategoryBox.maxFlowSize + 140 * scaledPixel)
    end
end

function FieldProfitabilityLedgerFrame:bindSortHeaders(headers, cycleHeaders)
    for _, header in ipairs(headers or {}) do
        header.onClickCallback = function()
            self:onSortHeader(header, cycleHeaders)
        end
    end
    self:updateSortHeaders(headers, cycleHeaders)
end

function FieldProfitabilityLedgerFrame:updateSortHeaders(headers, cycleHeaders)
    local sortBy = cycleHeaders and self.settings.cycleSortBy
        or self.comparisonSortBy
    local descending = cycleHeaders and self.settings.cycleSortDescending
        or self.comparisonDescending
    local constants = _G.TableHeaderElement
    local ascending = type(constants) == "table"
        and constants.SORTING_ASC or 2
    local desc = type(constants) == "table"
        and constants.SORTING_DESC or 3
    for _, header in ipairs(headers or {}) do
        local selected = header.columnName == sortBy
        if type(header.setSelected) == "function" then
            header:setSelected(selected)
        end
        if selected then
            header.sortingOrder = descending and desc or ascending
            if type(header.updateSortingDisplay) == "function" then
                header:updateSortingDisplay()
            end
        elseif type(header.disableSorting) == "function" then
            header:disableSorting()
        end
    end
end

function FieldProfitabilityLedgerFrame:onSortHeader(header, cycleHeaders)
    local key = type(header) == "table" and header.columnName or nil
    if type(key) ~= "string" then return end
    if cycleHeaders then
        if self.settings.cycleSortBy == key then
            self.settings.cycleSortDescending =
                not self.settings.cycleSortDescending
        else
            self.settings.cycleSortBy = key
            self.settings.cycleSortDescending =
                key ~= "field" and key ~= "crop"
                    and key ~= "state" and key ~= "quality"
        end
        self:saveSettings(false)
        self:updateSortHeaders(self.cycleSortHeaders, true)
        self:refreshCycleTable(true)
    else
        if self.comparisonSortBy == key then
            self.comparisonDescending = not self.comparisonDescending
        else
            self.comparisonSortBy = key
            self.comparisonDescending = key ~= "field"
        end
        self:updateSortHeaders(self.comparisonSortHeaders, false)
        self:refreshComparison()
    end
end

function FieldProfitabilityLedgerFrame:onFrameOpen()
    FieldProfitabilityLedgerFrame:superClass().onFrameOpen(self)
    self.isFrameOpen = true
    self.refreshElapsedMs = 0
    self:resetSessionFilters()
    self:applyView("cycles")
    self:refreshCycleTable(true)
    self.lastRenderedRevision = self.report ~= nil
        and type(self.report.getRevision) == "function"
        and self.report:getRevision() or nil
    focus(self.cycleList)
end

function FieldProfitabilityLedgerFrame:onFrameClose()
    FieldProfitabilityLedgerFrame:superClass().onFrameClose(self)
    self.isFrameOpen = false
    self.refreshElapsedMs = 0
    self.legacyRows = {}
    self.legacySelected = {}
    self.legacySelectionOrder = {}
end

function FieldProfitabilityLedgerFrame:update(dt)
    local resolver = rawget(FieldProfitabilityLedgerFrame, "superClass")
    local super = type(resolver) == "function"
        and resolver(FieldProfitabilityLedgerFrame) or nil
    if type(super) == "table" and type(super.update) == "function" then
        super.update(self, dt)
    end
    if not self.isFrameOpen or self.report == nil then return end
    self.refreshElapsedMs = self.refreshElapsedMs
        + (finiteNumber(dt) and dt or 0)
    if self.refreshElapsedMs < 1000 then return end
    self.refreshElapsedMs = self.refreshElapsedMs % 1000
    local revision = type(self.report.getRevision) == "function"
        and self.report:getRevision() or nil
    if revision == nil or revision ~= self.lastRenderedRevision then
        self:refreshCycleTable(false)
        self.lastRenderedRevision = revision
    end
end

function FieldProfitabilityLedgerFrame:resetSessionFilters()
    self.cycleScope = "current"
    self.cycleCrop = nil
    self.cycleQuality = nil
    self.cycleSearch = nil
    self.cycleSearchQuery = nil
    self.groupByField = false
    self.cycleRowsByAbsolute = {}
    self.cyclePathById = {}
    self:updateFilterControls()
end

function FieldProfitabilityLedgerFrame:applyView(name)
    local accepted = false
    for _, value in ipairs(TAB_ORDER) do
        if value == name then accepted = true break end
    end
    if not accepted then return end
    self.currentView = name
    for _, value in ipairs(TAB_ORDER) do
        setVisible(self[value .. "Panel"], value == name)
    end
    setVisible(self.legacyPanel, false)
    for index, value in ipairs(TAB_ORDER) do
        local tab = self.tabElements[index]
        if type(tab) == "table" and type(tab.setSelected) == "function" then
            tab:setSelected(value == name)
        end
        if value == name and type(self.subCategoryPaging) == "table"
            and type(self.subCategoryPaging.setState) == "function" then
            self.subCategoryPaging:setState(index, false)
        end
    end
    if type(self.setMenuButtonInfoDirty) == "function" then
        self:setMenuButtonInfoDirty()
    end
end

function FieldProfitabilityLedgerFrame:showView(name)
    self:applyView(name)
    if name == "cycles" then
        reload(self.cycleList)
        local path = self.cyclePathById[self.selectedCycleId]
        if path ~= nil then
            setSelectedPath(self.cycleList, path.section, path.index)
        end
        focus(self.cycleList)
    elseif name == "settings" then
        self:refreshSettings()
    else
        self:refreshSelected()
        if name == "activity" then focus(self.activityList)
        elseif name == "comparison" then focus(self.comparisonList) end
    end
end

function FieldProfitabilityLedgerFrame:onClickTab(state)
    self:showView(TAB_ORDER[tonumber(state) or 1] or "cycles")
end

function FieldProfitabilityLedgerFrame:onClickCycles()
    self:showView("cycles")
end

function FieldProfitabilityLedgerFrame:onClickOverview()
    self:showView("overview")
end

function FieldProfitabilityLedgerFrame:onClickActivity()
    self:showView("activity")
end

function FieldProfitabilityLedgerFrame:onClickScenario()
    self:showView("scenario")
end

function FieldProfitabilityLedgerFrame:onClickComparison()
    self:showView("comparison")
end

function FieldProfitabilityLedgerFrame:onClickSettings()
    self:showView("settings")
end

function FieldProfitabilityLedgerFrame:scenarioSwitches()
    return {
        direct=self.settings.includeDirect,
        inputs=self.settings.includeInputs,
        fuel=self.settings.includeFuel,
        def=self.settings.includeDef,
        allocated=self.settings.includeAllocated
    }
end

function FieldProfitabilityLedgerFrame:cycleOptions(offset, limit)
    return {
        scope=self.cycleScope,
        crop=self.cycleCrop,
        quality=self.cycleQuality,
        search=self.cycleSearchQuery or self.cycleSearch,
        groupByField=self.groupByField,
        sortBy=self.settings.cycleSortBy,
        descending=self.settings.cycleSortDescending,
        scenario=self:scenarioSwitches(),
        offset=offset or 0,
        limit=limit == nil and PAGE_SIZE or limit
    }
end

function FieldProfitabilityLedgerFrame:fetchCyclePage(absoluteIndex)
    if self.report == nil or absoluteIndex < 1 then return nil end
    local pageOffset = math.floor((absoluteIndex - 1) / PAGE_SIZE) * PAGE_SIZE
    if self.cycleRowsByAbsolute[pageOffset + 1] == nil then
        local result, reason = self.report:listCycleTable(
            self:cycleOptions(pageOffset, PAGE_SIZE))
        if result == nil then
            self:setStatus(failureMessage("fpl_queryFailed", "query", reason))
            return nil
        end
        for _, row in ipairs(result.rows or {}) do
            self.cycleRowsByAbsolute[row.absoluteIndex] = row
            self.cyclePathById[row.cycle.id] = {
                section=row.sectionIndex,
                index=row.indexInSection,
                absolute=row.absoluteIndex
            }
        end
    end
    return self.cycleRowsByAbsolute[absoluteIndex]
end

function FieldProfitabilityLedgerFrame:findSelectedCyclePath()
    local existing = self.cyclePathById[self.selectedCycleId]
    if existing ~= nil then return existing end
    local total = self.cycleTable ~= nil
        and self.cycleTable.page.total or 0
    local offset = 0
    while self.selectedCycleId ~= nil and offset < total do
        self:fetchCyclePage(offset + 1)
        local found = self.cyclePathById[self.selectedCycleId]
        if found ~= nil then return found end
        offset = offset + PAGE_SIZE
    end
    return nil
end

function FieldProfitabilityLedgerFrame:refreshCycleTable(resetScroll)
    if self.report == nil or type(self.report.listCycleTable) ~= "function" then
        self.cycleTable = {page={total=0}, sections={}}
        self.cycleSections = {}
        reload(self.cycleList)
        self:setStatus(text("fpl_runtimeInactive"))
        return nil
    end
    local result, reason = self.report:listCycleTable(self:cycleOptions(0, 0))
    if result == nil then
        self:setStatus(failureMessage("fpl_queryFailed", "query", reason))
        return nil
    end
    self.cycleTable = result
    self.cycleSections = result.sections or {}
    self.cycleRowsByAbsolute = {}
    self.cyclePathById = {}
    self:updateFacetControls(result.facets)
    self:updateSortHeaders(self.cycleSortHeaders, true)
    setText(self.cycleCountText,
        formatted("fpl_cycleCount", result.page.total or 0))
    setDisabled(self.viewCycleButton, (result.page.total or 0) == 0)
    if (result.page.total or 0) == 0 then
        self.selectedCycleId = nil
        self.selectedRecordId = nil
        self.selectedRecordValue = nil
        reload(self.cycleList)
    else
        self:fetchCyclePage(1)
        local path = self:findSelectedCyclePath()
        if path == nil then
            local first = self:fetchCyclePage(1)
            self.selectedCycleId = first ~= nil and first.cycle.id or nil
            path = self.cyclePathById[self.selectedCycleId]
        end
        reload(self.cycleList)
        if path ~= nil then
            setSelectedPath(self.cycleList, path.section, path.index)
        end
        if resetScroll and type(self.cycleList) == "table"
            and type(self.cycleList.scrollTo) == "function" then
            pcall(self.cycleList.scrollTo, self.cycleList, 0)
        end
    end
    if self.currentView ~= "cycles" and self.selectedCycleId ~= nil then
        self:refreshSelected()
    end
    return result
end

function FieldProfitabilityLedgerFrame:updateFilterControls()
    local scopes = {
        text("fpl_cycleCurrent"),
        text("fpl_cycleHistory"),
        text("fpl_cycleAll")
    }
    if type(self.cycleScopeOption) == "table" then
        if type(self.cycleScopeOption.setTexts) == "function" then
            self.cycleScopeOption:setTexts(scopes)
        end
        local state = self.cycleScope == "current" and 1
            or self.cycleScope == "history" and 2 or 3
        if type(self.cycleScopeOption.setState) == "function" then
            self.cycleScopeOption:setState(state, false)
        end
    end
    setText(self.cycleSearchButton,
        self.cycleSearch ~= nil
            and formatted("fpl_searchValue", self.cycleSearch)
            or text("fpl_search"))
    setText(self.cycleGroupButton,
        formatted("fpl_groupByFieldValue", booleanLabel(self.groupByField)))
end

function FieldProfitabilityLedgerFrame:updateFacetControls(facets)
    facets = facets or {}
    self.cropFacetValues, self.qualityFacetValues = {false}, {false}
    local cropTexts, qualityTexts = {
        text("fpl_filterAll")
    }, {text("fpl_filterAll")}
    for _, facet in ipairs(facets.crops or {}) do
        self.cropFacetValues[#self.cropFacetValues + 1] = facet.value
        cropTexts[#cropTexts + 1] = cropLabel({fruitType=facet.value})
    end
    for _, facet in ipairs(facets.qualities or {}) do
        self.qualityFacetValues[#self.qualityFacetValues + 1] = facet.value
        qualityTexts[#qualityTexts + 1] = qualityLabel(facet.value)
    end
    local function apply(option, values, texts, selected)
        if type(option) ~= "table" then return end
        if type(option.setTexts) == "function" then option:setTexts(texts) end
        local state = 1
        for index, value in ipairs(values) do
            if value == selected then state = index break end
        end
        if type(option.setState) == "function" then
            option:setState(state, false)
        end
    end
    apply(self.cycleCropOption, self.cropFacetValues, cropTexts, self.cycleCrop)
    apply(self.cycleQualityOption, self.qualityFacetValues,
        qualityTexts, self.cycleQuality)
    self:updateFilterControls()
end

function FieldProfitabilityLedgerFrame:onClickCycleScope(state)
    local value = ({"current", "history", "all"})[tonumber(state) or 1]
    self.cycleScope = value or "current"
    if self.cycleScope == "history" then self.groupByField = true end
    self:updateFilterControls()
    self:refreshCycleTable(true)
end

function FieldProfitabilityLedgerFrame:onClickCycleCrop(state)
    local value = self.cropFacetValues ~= nil
        and self.cropFacetValues[tonumber(state) or 1] or false
    self.cycleCrop = value or nil
    self:refreshCycleTable(true)
end

function FieldProfitabilityLedgerFrame:onClickCycleQuality(state)
    local value = self.qualityFacetValues ~= nil
        and self.qualityFacetValues[tonumber(state) or 1] or false
    self.cycleQuality = value or nil
    self:refreshCycleTable(true)
end

function FieldProfitabilityLedgerFrame:onClickCycleGroup()
    self.groupByField = not self.groupByField
    self:updateFilterControls()
    self:refreshCycleTable(true)
end

function FieldProfitabilityLedgerFrame:onClickCycleSearch()
    local shown = showTextInput(
        FieldProfitabilityLedgerFrame.onCycleSearchEntered,
        self,
        self.cycleSearch or "",
        text("fpl_searchDialogTitle"))
    if shown == nil then self:setStatus(text("fpl_textInputUnavailable")) end
end

function FieldProfitabilityLedgerFrame:onCycleSearchEntered(value, confirmed)
    if confirmed ~= true then return end
    value = type(value) == "string" and value:match("^%s*(.-)%s*$") or ""
    self.cycleSearch = value ~= "" and value or nil
    self.cycleSearchQuery = self.cycleSearch ~= nil
        and canonicalLandSearch(self.cycleSearch) or nil
    self:updateFilterControls()
    self:refreshCycleTable(true)
end

function FieldProfitabilityLedgerFrame:getNumberOfSections(list)
    if list == self.cycleList then return #self.cycleSections end
    return 1
end

function FieldProfitabilityLedgerFrame:getNumberOfItemsInSection(list, section)
    if list == self.cycleList then
        local value = self.cycleSections[section]
        return value ~= nil and value.count or 0
    elseif list == self.totalsList then
        return self.selectedDetail ~= nil
            and #(self.selectedDetail.categoryTotals or {}) or 0
    elseif list == self.activityList then
        return self.selectedDetail ~= nil
            and (self.selectedDetail.recordPage.total or 0) or 0
    elseif list == self.comparisonList then
        return #self.comparisonRows
    elseif list == self.legacyList then
        return #self.legacyRows
    end
    return 0
end

function FieldProfitabilityLedgerFrame:getTitleForSectionHeader(list, section)
    if list ~= self.cycleList or not self.groupByField then return nil end
    local value = self.cycleSections[section]
    return value ~= nil and landLabel(value.cycle or {}) or nil
end

function FieldProfitabilityLedgerFrame:getCycleRow(section, index)
    local value = self.cycleSections[section]
    if value == nil then return nil end
    return self:fetchCyclePage((value.offset or 0) + index)
end

function FieldProfitabilityLedgerFrame:getActivityRecord(index)
    if self.report == nil or self.selectedCycleId == nil
        or self.selectedDetail == nil then return nil end
    local pageOffset = math.floor((index - 1) / PAGE_SIZE) * PAGE_SIZE
    if self.activityRowsByAbsolute[pageOffset + 1] == nil then
        local detail, reason = self.report:cycleDetail(self.selectedCycleId, {
            includeExcluded=self.settings.showExcluded,
            recordOffset=pageOffset,
            recordLimit=PAGE_SIZE
        })
        if detail == nil then
            self:setStatus(failureMessage("fpl_queryFailed", "query", reason))
            return nil
        end
        for localIndex, record in ipairs(detail.records or {}) do
            self.activityRowsByAbsolute[pageOffset + localIndex] = record
        end
    end
    return self.activityRowsByAbsolute[index]
end

function FieldProfitabilityLedgerFrame:populateCellForItemInSection(
        list, section, index, cell)
    if list == self.cycleList then
        local row = self:getCycleRow(section, index)
        if row == nil then return end
        setCell(cell, "field", landLabel(row.cycle))
        setCell(cell, "crop", cropLabel(row.cycle))
        setCell(cell, "state", stateLabel(row.cycle.state))
        setCell(cell, "period", cyclePeriod(row.cycle))
        setCell(cell, "area", unitValue(row.cycle.cycleAreaHa, "hectares"))
        setCell(cell, "yieldPerHa", yieldPerHa(row.yieldLitresPerHa))
        setCell(cell, "valuePerHa", moneyPerHa(row.valuePerHa))
        setCell(cell, "costPerHa", moneyPerHa(row.costPerHa))
        setCell(cell, "marginPerHa", moneyPerHa(row.marginPerHa))
        setCell(cell, "quality", qualityLabel(row.qualityClass))
        if finiteNumber(row.marginPerHa) then
            setCellColour(cell, "marginPerHa",
                row.marginPerHa < 0 and {0.92, 0.32, 0.26, 1}
                    or {0.45, 0.90, 0.48, 1})
        end
    elseif list == self.totalsList then
        local total = self.selectedDetail ~= nil
            and self.selectedDetail.categoryTotals[index] or nil
        if total == nil then return end
        setCell(cell, "name", classLabel(total.accountingClass)
            .. "  ·  " .. categoryLabel(total.category))
        setCell(cell, "value", unitValue(total.amount, total.unit))
    elseif list == self.activityList then
        local record = self:getActivityRecord(index)
        if record == nil then return end
        setCell(cell, "time", missionTimeLabel(record.missionTime))
        setCell(cell, "type", recordTypeLabel(record.recordType))
        setCell(cell, "category", categoryLabel(record.category))
        setCell(cell, "class", classLabel(record.accountingClass))
        setCell(cell, "amount",
            unitValue(record.adjustedAmount or record.amount, record.unit))
        setCell(cell, "quality", qualityLabel(record.qualityClass))
        setCell(cell, "status", record.excluded and text("fpl_excluded")
            or record.unallocated and text("fpl_unallocated")
            or text("fpl_included"))
    elseif list == self.comparisonList then
        local row = self.comparisonRows[index]
        if row == nil then return end
        setCell(cell, "field", landLabel(row.cycle)
            .. (row.selected and "  *" or ""))
        setCell(cell, "period", cyclePeriod(row.cycle))
        setCell(cell, "yieldPerHa", yieldPerHa(row.yieldLitresPerHa))
        setCell(cell, "valuePerHa", moneyPerHa(row.valuePerHa))
        setCell(cell, "costPerHa", moneyPerHa(row.costPerHa))
        setCell(cell, "marginPerHa", moneyPerHa(row.marginPerHa))
        if finiteNumber(row.marginPerHa) then
            setCellColour(cell, "marginPerHa",
                row.marginPerHa < 0 and {0.92, 0.32, 0.26, 1}
                    or {0.45, 0.90, 0.48, 1})
        end
        local geometry = self.comparisonGeometry
        local bar = geometry ~= nil and geometry.bars[index] or nil
        local track = attribute(cell, "chartTrack")
        local fill = attribute(cell, "chartFill")
        local zero = attribute(cell, "chartZero")
        local average = attribute(cell, "chartAverage")
        local trackX = type(track) == "table" and track.position
            and track.position[1] or 0
        local trackY = type(track) == "table" and track.position
            and track.position[2] or 0
        local trackWidth = type(track) == "table" and track.size
            and track.size[1] or 0
        local trackHeight = type(track) == "table" and track.size
            and track.size[2] or 0
        setVisible(fill, bar ~= nil and bar.available)
        if bar ~= nil and bar.available then
            setPosition(fill, trackX + trackWidth * bar.start, trackY)
            setSize(fill, trackWidth * bar.width, trackHeight)
            setImageColor(fill, bar.negative
                and {0.84, 0.27, 0.23, 1}
                    or {0.36, 0.72, 0.42, 1})
        end
        if geometry ~= nil then
            setVisible(zero, true)
            setPosition(zero, trackX + trackWidth * geometry.zeroFraction,
                type(zero) == "table" and zero.position
                    and zero.position[2] or trackY)
            setVisible(average, geometry.averageFraction ~= nil)
            if geometry.averageFraction ~= nil then
                setPosition(average,
                    trackX + trackWidth * geometry.averageFraction,
                    type(average) == "table" and average.position
                        and average.position[2] or trackY)
            end
        end
    elseif list == self.legacyList then
        local row = self.legacyRows[index]
        if row == nil then return end
        setCell(cell, "field", landLabel(row.cycle))
        setCell(cell, "crop", cropLabel(row.cycle))
        setCell(cell, "harvest", formatted("fpl_harvestAt",
            missionTimeLabel(row.evidence.lastHarvestMissionTime)))
        setCell(cell, "activity", formatted("fpl_activityAt",
            missionTimeLabel(row.evidence.lastActivityMissionTime)))
        setCell(cell, "selected", self.legacySelected[row.cycle.id] ~= nil
            and text("fpl_legacyCandidateSelected")
            or text("fpl_legacyCandidateExcluded"))
    end
end

function FieldProfitabilityLedgerFrame:onCycleListClick(
        list, section, index)
    local row = self:getCycleRow(section, index)
    if row == nil then return end
    self.selectedCycleId = row.cycle.id
    self.selectedRecordId = nil
    self.selectedRecordValue = nil
    self.cyclePathById[row.cycle.id] = {
        section=section, index=index, absolute=row.absoluteIndex}
    setDisabled(self.viewCycleButton, false)
end

function FieldProfitabilityLedgerFrame:onCycleListDoubleClick(
        list, section, index)
    self:onCycleListClick(list, section, index)
    self:showView("overview")
end

function FieldProfitabilityLedgerFrame:onClickViewCycle()
    if self.selectedCycleId == nil then
        self:setStatus(text("fpl_selectCycle"))
        return
    end
    self:showView("overview")
end

function FieldProfitabilityLedgerFrame:selectedScenario()
    if self.report == nil or self.selectedCycleId == nil then return nil end
    local base = self.report:scenario(self.selectedCycleId)
    if base == nil then return nil end
    local parts, allocated = base.parts or {}, {}
    for key in pairs(parts.allocatedCosts or {}) do
        allocated[key] = self.settings.includeAllocated
    end
    return self.report:scenario(self.selectedCycleId, {
        direct=self.settings.includeDirect
            and parts.directObservedCosts ~= nil,
        inputs=self.settings.includeInputs
            and parts.replacementValuedInputs ~= nil,
        fuel=self.settings.includeFuel
            and parts.replacementFuelValue ~= nil,
        def=self.settings.includeDef
            and parts.replacementDefValue ~= nil,
        allocated=allocated
    })
end

function FieldProfitabilityLedgerFrame:refreshSelected()
    if self.report == nil or self.selectedCycleId == nil then return nil end
    local selectedRecordId = self.selectedRecordId
    local detail, reason = self.report:cycleDetail(self.selectedCycleId, {
        includeExcluded=self.settings.showExcluded,
        recordOffset=0,
        recordLimit=0
    })
    if detail == nil then
        self:setStatus(failureMessage("fpl_queryFailed", "query", reason))
        return nil
    end
    self.selectedDetail = detail
    self.activityRowsByAbsolute = {}
    self.selectedRecordId = selectedRecordId
    self.selectedRecordValue = nil
    local title = landLabel(detail.cycle) .. "  ·  " .. cropLabel(detail.cycle)
    local meta = formatted("fpl_selectedMeta",
        stateLabel(detail.cycle.state),
        unitValue(detail.cycle.cycleAreaHa, "hectares"))
    setText(self.selectedTitle, title)
    setText(self.activityTitle, title)
    setText(self.scenarioTitle, title)
    setText(self.comparisonTitle, title)
    setText(self.selectedMeta, meta)
    setText(self.overviewAreaValue,
        unitValue(detail.cycle.cycleAreaHa, "hectares"))
    setText(self.yieldValue, yieldPerHa(detail.yieldLitresPerHa))
    setVisible(self.closeCycleButton, detail.cycle.state == "open")
    reload(self.totalsList)
    reload(self.activityList)

    local totals = {}
    for _, total in ipairs(detail.categoryTotals or {}) do
        totals[total.category] = total
    end
    local function total(category, unit)
        local value = totals[category]
        return value ~= nil and unitValue(value.amount, value.unit)
            or unitValue(nil, unit)
    end
    setText(self.activityLiveTotals, formatted("fpl_activityLiveTotals",
        total("aiLabourTime", "milliseconds"),
        total("workingTime", "milliseconds"),
        total("harvest", "litres"),
        total("ordinaryArableHarvest", "hectares")))

    local scenario = self:selectedScenario()
    if scenario ~= nil and scenario.available then
        local marginPerHa = nil
        if detail.cycle.cycleAreaHa ~= nil
            and detail.cycle.cycleAreaHa > 0 then
            marginPerHa = scenario.result.estimatedGrossMargin
                / detail.cycle.cycleAreaHa
        end
        local valuePerHa = nil
        if detail.cycle.cycleAreaHa ~= nil
            and detail.cycle.cycleAreaHa > 0 then
            valuePerHa = scenario.result.estimatedHarvestValue
                / detail.cycle.cycleAreaHa
        end
        setText(self.overviewValuePerHa, moneyPerHa(valuePerHa))
        setText(self.overviewCostPerHa, moneyPerHa(scenario.cycleCostPerHa))
        setText(self.overviewMarginPerHa, moneyPerHa(marginPerHa))
        setText(self.scenarioHarvestValue,
            displayMoney(scenario.result.estimatedHarvestValue))
        setText(self.scenarioCostValue,
            displayMoney(scenario.result.totalSelectedCosts))
        setText(self.scenarioMarginValue,
            displayMoney(scenario.result.estimatedGrossMargin))
        setText(self.scenarioCostPerHaValue,
            moneyPerHa(scenario.cycleCostPerHa))
        setText(self.scenarioMarginPerHaValue, moneyPerHa(marginPerHa))
        setVisible(self.scenarioUnavailableText, false)
        setText(self.scenarioStatus, classLabel(scenario.accountingClass))
    else
        setText(self.overviewValuePerHa, text("fpl_unavailable"))
        setText(self.overviewCostPerHa, text("fpl_unavailable"))
        setText(self.overviewMarginPerHa, text("fpl_unavailable"))
        setText(self.scenarioHarvestValue, text("fpl_unavailable"))
        setText(self.scenarioCostValue, text("fpl_unavailable"))
        setText(self.scenarioMarginValue, text("fpl_unavailable"))
        setText(self.scenarioCostPerHaValue, text("fpl_unavailable"))
        setText(self.scenarioMarginPerHaValue, text("fpl_unavailable"))
        setVisible(self.scenarioUnavailableText, true)
        setText(self.scenarioUnavailableText, scenario ~= nil
            and formatted("fpl_unavailableReason",
                reasonLabel(scenario.reason))
            or text("fpl_scenarioUnavailable"))
    end
    self:refreshSettingLabels()
    if self.currentView == "comparison" then self:refreshComparison() end
    return detail
end

function FieldProfitabilityLedgerFrame:onActivityListClick(list, section, index)
    local record = self:getActivityRecord(index)
    if record == nil then return end
    self.selectedRecordId = record.id
    self.selectedRecordValue = record
    self:setStatus(formatted("fpl_selectedRecord",
        categoryLabel(record.category)))
end

function FieldProfitabilityLedgerFrame:onActivityListDoubleClick(
        list, section, index)
    self:onActivityListClick(list, section, index)
    self:onClickActivityDetails()
end

function FieldProfitabilityLedgerFrame:selectedRecord()
    if self.selectedRecordId == nil or self.selectedDetail == nil then return nil end
    if type(self.selectedRecordValue) == "table"
        and self.selectedRecordValue.id == self.selectedRecordId then
        return self.selectedRecordValue
    end
    local total = self.selectedDetail.recordPage.total or 0
    for index=1,total do
        local record = self:getActivityRecord(index)
        if record ~= nil and record.id == self.selectedRecordId then
            self.selectedRecordValue = record
            return record
        end
    end
    return nil
end

function FieldProfitabilityLedgerFrame:onClickActivityDetails()
    local record = self:selectedRecord()
    if record == nil then
        self:setStatus(text("fpl_selectRecord"))
        return
    end
    local lines = {
        formatted("fpl_detailId", tostring(record.id or "")),
        formatted("fpl_detailTime", missionTimeLabel(record.missionTime)),
        formatted("fpl_detailType", recordTypeLabel(record.recordType)),
        formatted("fpl_detailCategory", categoryLabel(record.category)),
        formatted("fpl_detailClass", classLabel(record.accountingClass)),
        formatted("fpl_detailQuality", qualityLabel(record.qualityClass)),
        formatted("fpl_detailAmount", unitValue(record.amount, record.unit)),
        formatted("fpl_detailAdjusted",
            unitValue(record.adjustedAmount, record.unit)),
        formatted("fpl_detailDirection", tostring(record.direction or "—")),
        formatted("fpl_detailExcluded", booleanLabel(record.excluded == true)),
        formatted("fpl_detailProvenance",
            simpleValue(record.provenance or record.source or record.references)),
        formatted("fpl_detailReasons", simpleValue(record.reasons)),
        formatted("fpl_detailReferences", simpleValue(record.references))
    }
    local dialog = _G.InfoDialog
    if type(dialog) == "table" and type(dialog.show) == "function" then
        dialog.show(table.concat(lines, "\n"), nil, self)
    else
        self:setStatus(text("fpl_infoDialogUnavailable"))
    end
end

function FieldProfitabilityLedgerFrame:onClickSetAlias()
    if self.commands == nil or self.selectedCycleId == nil then
        self:setStatus(text("fpl_runtimeInactive"))
        return
    end
    local current = self.commands:getAliasForCycle(self.selectedCycleId)
    local shown = showTextInput(
        FieldProfitabilityLedgerFrame.onAliasEntered,
        self,
        type(current) == "table" and current.alias or "",
        text("fpl_aliasDialogTitle"),
        self.selectedCycleId)
    if shown == nil then self:setStatus(text("fpl_textInputUnavailable")) end
end

function FieldProfitabilityLedgerFrame:onAliasEntered(
        value, confirmed, cycleId)
    if confirmed ~= true or self.commands == nil then return end
    local result, reason = self.commands:setAliasForCycle(cycleId, value)
    if result == nil then
        self:setStatus(failureMessage("fpl_editFailed", "edit", reason))
        return
    end
    self:setStatus(formatted("fpl_aliasSaved",
        type(result.alias) == "string" and result.alias or value))
    self:refreshCycleTable(false)
    self:refreshSelected()
end

function FieldProfitabilityLedgerFrame:onClickCloseCycle()
    if self.commands == nil or self.selectedCycleId == nil then
        self:setStatus(text("fpl_runtimeInactive"))
        return
    end
    local shown = showTextInput(
        FieldProfitabilityLedgerFrame.onCloseCycleConfirmed,
        self, "", text("fpl_closeCycleDialogTitle"), self.selectedCycleId)
    if shown == nil then self:setStatus(text("fpl_textInputUnavailable")) end
end

function FieldProfitabilityLedgerFrame:onCloseCycleConfirmed(
        value, confirmed, cycleId)
    if confirmed ~= true or value ~= text("fpl_closeCycleConfirmation") then
        self:setStatus(text("fpl_closeCycleCancelled"))
        return
    end
    local result, reason = self.commands:closeCycle(cycleId)
    if result == nil then
        self:setStatus(failureMessage(
            "fpl_cycleCloseFailed", "closeCycle", reason))
        return
    end
    self:setStatus(text("fpl_cycleClosed"))
    self:refreshCycleTable(false)
    self:showView("overview")
end

function FieldProfitabilityLedgerFrame:onClickExcludeSelected()
    local record = self:selectedRecord()
    if record == nil then
        self:setStatus(text("fpl_selectRecord"))
        return
    end
    local shown = showTextInput(
        FieldProfitabilityLedgerFrame.onExclusionEntered,
        self, "", text("fpl_exclusionDialogTitle"),
        {cycleId=self.selectedCycleId, recordId=record.id})
    if shown == nil then self:setStatus(text("fpl_textInputUnavailable")) end
end

function FieldProfitabilityLedgerFrame:onExclusionEntered(
        value, confirmed, context)
    if confirmed ~= true or self.commands == nil then return end
    local result, reason = self.commands:excludeRecord(
        context.cycleId, context.recordId, value)
    if result == nil then
        self:setStatus(failureMessage("fpl_editFailed", "edit", reason))
        return
    end
    self:setStatus(text("fpl_exclusionSaved"))
    self:refreshSelected()
end

function FieldProfitabilityLedgerFrame:onClickCorrectSelected()
    local record = self:selectedRecord()
    if record == nil then
        self:setStatus(text("fpl_selectRecord"))
        return
    end
    local shown = showTextInput(
        FieldProfitabilityLedgerFrame.onCorrectionDeltaEntered,
        self, "", formatted(
            "fpl_correctionDeltaDialogTitle",
            unitValue(1, record.unit)),
        {cycleId=self.selectedCycleId, recordId=record.id})
    if shown == nil then self:setStatus(text("fpl_textInputUnavailable")) end
end

function FieldProfitabilityLedgerFrame:onCorrectionDeltaEntered(
        value, confirmed, context)
    if confirmed ~= true then return end
    local delta = parseDelta(value)
    if delta == nil then
        self:setStatus(text("fpl_invalidCorrectionDelta"))
        return
    end
    context.delta = delta
    local shown = showTextInput(
        FieldProfitabilityLedgerFrame.onCorrectionReasonEntered,
        self, "", text("fpl_correctionReasonDialogTitle"), context)
    if shown == nil then self:setStatus(text("fpl_textInputUnavailable")) end
end

function FieldProfitabilityLedgerFrame:onCorrectionReasonEntered(
        value, confirmed, context)
    if confirmed ~= true or self.commands == nil then return end
    local result, reason = self.commands:correctRecord(
        context.cycleId, context.recordId, context.delta, value)
    if result == nil then
        self:setStatus(failureMessage("fpl_editFailed", "edit", reason))
        return
    end
    self:setStatus(text("fpl_correctionSaved"))
    self:refreshSelected()
end

function FieldProfitabilityLedgerFrame:refreshComparison()
    if self.report == nil or self.selectedCycleId == nil then return end
    local result, reason = self.report:comparison(self.selectedCycleId, {
        sortBy=self.comparisonSortBy,
        descending=self.comparisonDescending,
        offset=0,
        limit=PAGE_SIZE
    })
    if result == nil then
        self.comparisonRows = {}
        reload(self.comparisonList)
        self:setStatus(failureMessage("fpl_queryFailed", "query", reason))
        return
    end
    self.comparisonRows = result.rows or {}
    self.lastComparison = result
    local values = {}
    for index, row in ipairs(self.comparisonRows) do
        values[index] = row[self.comparisonMetric]
    end
    self.comparisonGeometry =
        FieldProfitabilityLedgerFrame.calculateChartGeometry(
            values,
            result.averages ~= nil
                and result.averages[self.comparisonMetric] or nil)
    setText(self.comparisonScopeText, formatted(
        "fpl_comparisonScope",
        result.scope.comparableCount or 0,
        result.scope.windowLimit or PAGE_SIZE))
    setText(self.comparisonMetricButton, formatted(
        "fpl_settingWithValue",
        text("fpl_chartMetric"),
        text("fpl_metric_" .. self.comparisonMetric)))
    reload(self.comparisonList)
    self:updateSortHeaders(self.comparisonSortHeaders, false)
end

function FieldProfitabilityLedgerFrame:onClickComparisonMetric()
    local current = 1
    for index, value in ipairs(COMPARISON_METRICS) do
        if value == self.comparisonMetric then current = index break end
    end
    self.comparisonMetric =
        COMPARISON_METRICS[current % #COMPARISON_METRICS + 1]
    self:refreshComparison()
end

function FieldProfitabilityLedgerFrame:refreshSettingLabels()
    local function labelled(button, key, value)
        setText(button, formatted("fpl_settingWithValue", text(key), value))
    end
    labelled(self.settingExcludedButton, "fpl_showExcluded",
        booleanLabel(self.settings.showExcluded))
    labelled(self.settingNewestButton, "fpl_csvOrder",
        self.settings.newestFirst
            and text("fpl_newestFirst") or text("fpl_oldestFirst"))
    for _, item in ipairs({
        {"Direct", "includeDirect", "fpl_includeDirect"},
        {"Inputs", "includeInputs", "fpl_includeInputs"},
        {"Fuel", "includeFuel", "fpl_includeFuel"},
        {"Def", "includeDef", "fpl_includeDef"},
        {"Allocated", "includeAllocated", "fpl_includeAllocated"}
    }) do
        local suffix, setting, key = item[1], item[2], item[3]
        local value = booleanLabel(self.settings[setting])
        labelled(self["setting" .. suffix .. "Button"], key, value)
        labelled(self["scenario" .. suffix .. "Button"], key, value)
    end
end

function FieldProfitabilityLedgerFrame:refreshSettings()
    self:refreshSettingLabels()
    if type(self.runtimeStatusProvider) ~= "function" then
        setText(self.runtimeCompatibilityValue,
            text("fpl_compatibilityUnavailable"))
        return
    end
    local ok, status = pcall(self.runtimeStatusProvider)
    if not ok or type(status) ~= "table" then
        setText(self.runtimeCompatibilityValue,
            text("fpl_compatibilityUnavailable"))
        return
    end
    local unavailable = {}
    for _, component in ipairs({
        "fieldWork", "application", "harvest", "machinery", "economics"
    }) do
        if status[component] ~= true then
            unavailable[#unavailable + 1] =
                text("fpl_component_" .. component)
        end
    end
    local value = #unavailable == 0
        and text("fpl_compatibilityAllActive")
        or formatted("fpl_compatibilityLimited",
            table.concat(unavailable, ", "))
    if status.saveState == "preservedPrevious" then
        value = value .. "\n" .. text("fpl_saveWarningPreserved")
    elseif status.saveState == "failed" then
        value = value .. "\n" .. text("fpl_saveWarningFailed")
    elseif (status.capacityCompactedCycles or 0) > 0 then
        value = value .. "\n" .. text("fpl_capacityCompactionNotice")
    end
    setText(self.runtimeCompatibilityValue, value)
end

function FieldProfitabilityLedgerFrame:saveSettings(refreshCycleTable)
    if self.settingsService == nil then return end
    local saved, reason = self.settingsService:set(self.settings)
    if saved == nil then
        self:setStatus(failureMessage(
            "fpl_settingsFailed", "settings", reason))
        return
    end
    self.settings = saved
    self:refreshSettingLabels()
    if refreshCycleTable ~= false then self:refreshCycleTable(false) end
end

function FieldProfitabilityLedgerFrame:onClickSettingNewest()
    self.settings.newestFirst = not self.settings.newestFirst
    self:saveSettings(false)
end

function FieldProfitabilityLedgerFrame:onClickSettingExcluded()
    self.settings.showExcluded = not self.settings.showExcluded
    self:saveSettings(false)
    if self.selectedCycleId ~= nil then self:refreshSelected() end
end

function FieldProfitabilityLedgerFrame:toggleScenarioSetting(key)
    self.settings[key] = not self.settings[key]
    self:saveSettings(true)
    if self.selectedCycleId ~= nil then self:refreshSelected() end
end

function FieldProfitabilityLedgerFrame:onClickSettingDirect()
    self:toggleScenarioSetting("includeDirect")
end

function FieldProfitabilityLedgerFrame:onClickSettingInputs()
    self:toggleScenarioSetting("includeInputs")
end

function FieldProfitabilityLedgerFrame:onClickSettingFuel()
    self:toggleScenarioSetting("includeFuel")
end

function FieldProfitabilityLedgerFrame:onClickSettingDef()
    self:toggleScenarioSetting("includeDef")
end

function FieldProfitabilityLedgerFrame:onClickSettingAllocated()
    self:toggleScenarioSetting("includeAllocated")
end

function FieldProfitabilityLedgerFrame:onClickReviewLegacyClosures()
    if self.commands == nil then
        self:setStatus(text("fpl_runtimeInactive"))
        return
    end
    local rows, offset, total = {}, 0, 0
    repeat
        local result, reason = self.commands:listLegacyClosureCandidates({
            offset=offset, limit=PAGE_SIZE})
        if result == nil then
            self:setStatus(failureMessage(
                "fpl_legacyClosureReviewFailed", "legacyClosure", reason))
            return
        end
        total = result.page.total or 0
        for _, row in ipairs(result.candidates or {}) do
            rows[#rows + 1] = row
        end
        offset = result.page.nextOffset
    until offset == nil
    self.legacyRows = rows
    self.legacySelected = {}
    self.legacySelectionOrder = {}
    setText(self.legacyReviewSummary, formatted(
        "fpl_legacyReviewSummary", total, 0, MAX_LEGACY_SELECTION))
    self:applyView("settings")
    setVisible(self.settingsPanel, false)
    setVisible(self.legacyPanel, true)
    reload(self.legacyList)
    focus(self.legacyList)
end

function FieldProfitabilityLedgerFrame:onLegacyListClick(
        list, section, index)
    local row = self.legacyRows[index]
    if row == nil or type(row.cycle) ~= "table" then return end
    local id = row.cycle.id
    if self.legacySelected[id] ~= nil then
        self.legacySelected[id] = nil
        for order, value in ipairs(self.legacySelectionOrder) do
            if value == id then table.remove(self.legacySelectionOrder, order) break end
        end
    else
        if #self.legacySelectionOrder >= MAX_LEGACY_SELECTION then
            self:setStatus(formatted(
                "fpl_legacySelectionLimit", MAX_LEGACY_SELECTION))
            return
        end
        self.legacySelected[id] = row
        self.legacySelectionOrder[#self.legacySelectionOrder + 1] = id
    end
    setText(self.legacyReviewSummary, formatted(
        "fpl_legacyReviewSummary", #self.legacyRows,
        #self.legacySelectionOrder, MAX_LEGACY_SELECTION))
    reload(self.legacyList)
end

function FieldProfitabilityLedgerFrame:onClickCancelLegacyReview()
    setVisible(self.legacyPanel, false)
    self:showView("settings")
    self:setStatus(text("fpl_legacyClosureCancelled"))
end

function FieldProfitabilityLedgerFrame:onClickCloseSelectedLegacyClosures()
    local selections, fields = {}, {}
    for _, id in ipairs(self.legacySelectionOrder) do
        local row = self.legacySelected[id]
        if row ~= nil and type(row.reviewSnapshot) == "table" then
            local snapshot = row.reviewSnapshot
            selections[#selections + 1] = {
                cycleId=id,
                reviewSnapshot={
                    revision=snapshot.revision,
                    lastHarvestRecordId=snapshot.lastHarvestRecordId,
                    lastHarvestMissionTime=snapshot.lastHarvestMissionTime,
                    lastActivityMissionTime=snapshot.lastActivityMissionTime
                }
            }
            fields[row.cycle.landKey or id] = true
        end
    end
    if #selections == 0 then
        self:setStatus(text("fpl_noLegacyClosureSelection"))
        return
    end
    local fieldCount = 0
    for _ in pairs(fields) do fieldCount = fieldCount + 1 end
    local shown = showTextInput(
        FieldProfitabilityLedgerFrame.onLegacyClosuresConfirmed,
        self, "",
        formatted("fpl_legacyClosureDialogTitle",
            #selections, fieldCount),
        {selections=selections})
    if shown == nil then self:setStatus(text("fpl_textInputUnavailable")) end
end

function FieldProfitabilityLedgerFrame:onLegacyClosuresConfirmed(
        value, confirmed, context)
    if confirmed ~= true or value ~= text("fpl_closeCycleConfirmation") then
        self:setStatus(text("fpl_legacyClosureCancelled"))
        return
    end
    local result, reason =
        self.commands:closeReviewedLegacyCycles(context.selections)
    if result == nil then
        self:setStatus(failureMessage(
            "fpl_legacyClosureFailed", "legacyClosure", reason))
        return
    end
    self:setStatus(formatted("fpl_legacyClosureComplete",
        #(result.closedCycles or {})))
    self:refreshCycleTable(false)
    self:onClickReviewLegacyClosures()
end

function FieldProfitabilityLedgerFrame:setStatus(value)
    setText(self.statusText, value)
    setText(self.overviewStatusText, value)
    setText(self.activityStatusText, value)
    setText(self.settingsStatusText, value)
end

function FieldProfitabilityLedgerFrame:onExport()
    if self.exporter == nil then
        self:setStatus(text("fpl_exportUnavailable"))
        return
    end
    local result, reason = self.exporter:export("cycles", {
        newestFirst=self.settings.newestFirst})
    self:setStatus(result ~= nil
        and formatted("fpl_exportSucceeded", result.path)
        or failureMessage("fpl_exportFailed", "export", reason))
end

function FieldProfitabilityLedgerFrame:onExportRecords()
    if self.exporter == nil or self.selectedCycleId == nil then
        self:setStatus(text("fpl_selectCycleForRecords"))
        return
    end
    local result, reason =
        self.exporter:export("records", self.selectedCycleId)
    self:setStatus(result ~= nil
        and formatted("fpl_exportSucceeded", result.path)
        or failureMessage("fpl_exportFailed", "export", reason))
end

function FieldProfitabilityLedgerFrame:onExportAudit()
    if self.exporter == nil or self.selectedCycleId == nil then
        self:setStatus(text("fpl_selectCycleForAudit"))
        return
    end
    local result, reason =
        self.exporter:export("audit", self.selectedCycleId)
    self:setStatus(result ~= nil
        and formatted("fpl_exportSucceeded", result.path)
        or failureMessage("fpl_exportFailed", "export", reason))
end

FieldProfitabilityLedger.Gui.LedgerFrame = FieldProfitabilityLedgerFrame
return FieldProfitabilityLedgerFrame
