-- Accessors for the active stopped DAP session.
local M = {}

---Return the active stopped DAP session, honoring an injected core seam first.
---@param core table|nil
---@return table|nil
function M.stopped(core)
  if core and core._stopped_session then
    return core._stopped_session()
  end
  if core and core._is_stopped and not core._is_stopped() then
    return nil
  end
  local ok, dap = pcall(require, 'dap')
  if not ok or not dap then
    return nil
  end
  local session = dap.session()
  if not session or not session.initialized or not session.stopped_thread_id or not session.current_frame then
    return nil
  end
  return session
end

---@param core table|nil
---@return boolean
function M.is_stopped(core)
  if core and core._is_stopped then
    return core._is_stopped()
  end
  return M.stopped(core) ~= nil
end

---@param core table|nil
---@param state table
---@param generation integer
---@param session table
---@return boolean
function M.is_current(core, state, generation, session)
  return state.generation == generation and M.is_stopped(core) and M.stopped(core) == session
end

return M
