-- Fixed profile-local export paths. No caller-supplied filename reaches I/O.

FieldProfitabilityLedger = FieldProfitabilityLedger or {}
FieldProfitabilityLedger.Persistence = FieldProfitabilityLedger.Persistence or {}

local ExportFilePort = {}
ExportFilePort.__index = ExportFilePort

local FILES = {
    cycles = "FieldProfitabilityLedger_cycles.csv",
    records = "FieldProfitabilityLedger_cycle_records.csv",
    audit = "FieldProfitabilityLedger_cycle_audit.csv"
}

local function validRoot(root)
    return type(root) == "string" and #root > 0
        and string.find(root, "\0", 1, true) == nil
end

local function join(root, suffix)
    local last = string.sub(root, -1)
    if last == "/" or last == "\\" then return root .. suffix end
    return root .. "/" .. suffix
end

local function defaultIo()
    local ioTable = _G.io
    local open = type(ioTable) == "table" and ioTable.open or nil
    local createDirectory = _G.createFolder
    local exists = _G.fileExists
    local copy = _G.copyFile
    local removeFile = _G.deleteFile
    if type(open) ~= "function" or type(createDirectory) ~= "function"
        or type(exists) ~= "function" or type(copy) ~= "function"
        or type(removeFile) ~= "function" then
        return nil
    end
    return {
        createFolder = createDirectory,
        open = function(path, mode)
            local openOk, handle = pcall(open, path, mode)
            if not openOk or type(handle) ~= "table"
                or type(handle.write) ~= "function"
                or type(handle.close) ~= "function" then
                return nil, "openFailed"
            end
            return {
                write = function(_, contents)
                    local ok, result = pcall(handle.write, handle, contents)
                    if not ok or result == false then return nil, "writeFailed" end
                    return true
                end,
                flush = function()
                    if type(handle.flush) ~= "function" then return true end
                    local ok, result = pcall(handle.flush, handle)
                    if not ok or result == false then return nil, "flushFailed" end
                    return true
                end,
                close = function()
                    local ok, result = pcall(handle.close, handle)
                    if not ok or result == false then return nil, "closeFailed" end
                    local existsOk, present = pcall(exists, path)
                    if not existsOk or present ~= true then return nil, "publishFailed" end
                    return true
                end
            }
        end,
        rename = function(source, target)
            local copyOk = pcall(copy, source, target, true)
            local targetOk, targetPresent = pcall(exists, target)
            if not copyOk or not targetOk or targetPresent ~= true then
                return nil, "copyFailed"
            end
            local deleteOk = pcall(removeFile, source)
            local sourceOk, sourcePresent = pcall(exists, source)
            if not deleteOk or not sourceOk or sourcePresent == true then
                return nil, "candidateCleanupFailed"
            end
            return true
        end,
        exists = function(path)
            local ok, present = pcall(exists, path)
            if not ok then return nil, "fileExistsFailed" end
            return present == true
        end,
        copy = function(source, target)
            local copyOk, copied = pcall(copy, source, target, true)
            local targetOk, targetPresent = pcall(exists, target)
            if not copyOk or copied == false or not targetOk
                or targetPresent ~= true then return nil, "copyFailed" end
            return true
        end,
        remove = function(path)
            local existsOk, present = pcall(exists, path)
            if not existsOk then return nil, "fileExistsFailed" end
            if present ~= true then return true end
            local deleteOk = pcall(removeFile, path)
            local finalOk, finalPresent = pcall(exists, path)
            if not deleteOk or not finalOk or finalPresent == true then
                return nil, "deleteFailed"
            end
            return true
        end
    }
end

function ExportFilePort.new(profileRoot, injected)
    if not validRoot(profileRoot) then return nil, "profileRootUnavailable" end
    local operations = injected or defaultIo()
    if type(operations) ~= "table"
        or type(operations.createFolder) ~= "function"
        or type(operations.open) ~= "function"
        or type(operations.rename) ~= "function"
        or type(operations.remove) ~= "function" then
        return nil, "exportIoUnavailable"
    end
    local settings = join(profileRoot, "modSettings")
    local module = join(settings, "FS25_FieldProfitabilityLedger")
    local directory = join(module, "exports")
    return setmetatable({
        operations = operations,
        directories = {settings, module, directory},
        directory = directory
    }, ExportFilePort)
end

function ExportFilePort:path(kind)
    local filename = FILES[kind]
    if filename == nil then return nil, "unknownExportKind" end
    return join(self.directory, filename)
end

function ExportFilePort:write(kind, contents)
    if type(contents) ~= "string" then return nil, "invalidExportContents" end
    if type(self.operations.exists) ~= "function"
        or type(self.operations.copy) ~= "function" then
        local target, reason = self:path(kind)
        if target == nil then return nil, reason end
        for _, directory in ipairs(self.directories) do
            if self.operations.createFolder(directory) == false then
                return nil, "exportDirectoryUnavailable"
            end
        end
        local candidate = target .. ".candidate"
        local handle, openReason = self.operations.open(candidate, "w")
        if handle == nil then return nil, openReason or "exportOpenFailed" end
        local wrote, writeReason = handle:write(contents)
        local flushed, flushReason = type(handle.flush) == "function"
            and handle:flush() or true
        local closed, closeReason = handle:close()
        if wrote == nil or wrote == false or flushed == nil or flushed == false
            or closed == nil or closed == false then
            self.operations.remove(candidate)
            return nil, writeReason or flushReason or closeReason
                or "exportWriteFailed"
        end
        local promoted, promoteReason = self.operations.rename(candidate, target)
        if promoted == nil or promoted == false then
            self.operations.remove(candidate)
            return nil, promoteReason or "exportPublishFailed"
        end
        return {path=target, bytes=#contents, kind=kind}
    end
    local transaction, reason = self:begin(kind)
    if transaction == nil then return nil, reason end
    local wrote
    wrote, reason = transaction:write(contents)
    if not wrote then transaction:abort(); return nil, reason end
    return transaction:commit()
end

function ExportFilePort:begin(kind)
    if type(self.operations.exists) ~= "function"
        or type(self.operations.copy) ~= "function" then
        return nil, "transactionalExportUnavailable"
    end
    local target, reason = self:path(kind)
    if target == nil then return nil, reason end
    for _, directory in ipairs(self.directories) do
        local ok = self.operations.createFolder(directory)
        if ok == false then return nil, "exportDirectoryUnavailable" end
    end
    local candidate = target .. ".candidate"
    local previous = target .. ".previous"
    local removed, removeReason = self.operations.remove(candidate)
    if removed == nil or removed == false then
        return nil, removeReason or "candidateCleanupFailed"
    end
    -- FS25's sandboxed io.open accepts the explicit write mode only.
    local handle, openReason = self.operations.open(candidate, "w")
    if handle == nil then return nil, openReason or "exportOpenFailed" end
    local transaction = {port=self, kind=kind, target=target,
        candidate=candidate, previous=previous, handle=handle,
        bytes=0, closed=false, published=false}
    function transaction:write(contents)
        if self.closed or type(contents) ~= "string" then
            return nil, self.closed and "exportTransactionClosed"
                or "invalidExportContents"
        end
        local called, wrote, writeReason = pcall(self.handle.write,
            self.handle, contents)
        if not called or wrote == nil or wrote == false then
            return nil, type(writeReason) == "string" and writeReason
                or "exportWriteFailed"
        end
        self.bytes = self.bytes + #contents
        return true
    end
    function transaction:_close()
        if self.closed then return true end
        local flushed, flushReason = true, nil
        if type(self.handle.flush) == "function" then
            local called
            called, flushed, flushReason = pcall(self.handle.flush, self.handle)
            if not called then flushed = nil end
        end
        local called, closed, closeReason = pcall(self.handle.close, self.handle)
        self.closed = true
        if flushed == nil or flushed == false or not called
            or closed == nil or closed == false then
            return nil, type(flushReason) == "string" and flushReason
                or (type(closeReason) == "string" and closeReason)
                or "exportWriteFailed"
        end
        local present, existsReason = self.port.operations.exists(self.candidate)
        if present ~= true then return nil, existsReason or "exportCandidateMissing" end
        return true
    end
    function transaction:abort()
        if not self.closed then pcall(self.handle.close, self.handle) end
        self.closed = true
        self.port.operations.remove(self.candidate)
        return true
    end
    function transaction:commit()
        if self.published then return nil, "exportTransactionClosed" end
        local closed, closeReason = self:_close()
        if not closed then self:abort(); return nil, closeReason end
        local targetPresent, existsReason = self.port.operations.exists(self.target)
        if targetPresent == nil then self:abort(); return nil, existsReason end
        self.port.operations.remove(self.previous)
        if targetPresent then
            local backed, backupReason = self.port.operations.copy(
                self.target, self.previous)
            if backed == nil or backed == false then
                self:abort()
                return nil, backupReason or "exportBackupFailed"
            end
        end
        local promoted, promoteReason = self.port.operations.copy(
            self.candidate, self.target)
        if promoted == nil or promoted == false then
            if targetPresent then
                local restored, restoreReason = self.port.operations.copy(
                    self.previous, self.target)
                self.port.operations.remove(self.candidate)
                if restored == nil or restored == false then
                    return nil, restoreReason or "exportRestoreFailed"
                end
                self.port.operations.remove(self.previous)
            else
                self.port.operations.remove(self.target)
                self.port.operations.remove(self.candidate)
            end
            return nil, promoteReason or "exportPublishFailed"
        end
        self.port.operations.remove(self.candidate)
        self.port.operations.remove(self.previous)
        self.published = true
        return {path=self.target, bytes=self.bytes, kind=self.kind}
    end
    return transaction
end

FieldProfitabilityLedger.Persistence.ExportFilePort = ExportFilePort
return ExportFilePort
