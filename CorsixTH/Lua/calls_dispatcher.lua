--[[ Copyright (c) 2010 Sam Wong

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
of the Software, and to permit persons to whom the Software is furnished to do
so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE. --]]

corsixth.require("announcer")

local AnnouncementPriority = _G["AnnouncementPriority"]

class "CallsDispatcher"

---@type CallsDispatcher
local CallsDispatcher = _G["CallsDispatcher"]

local debug = false -- Turn on for debug message

function CallsDispatcher:CallsDispatcher(world)
  self.world = world
  self.call_queue = {}
  self.change_callback = {}
  self.tick = 0
  self.auto_fill_rooms = {}
  self._auto_fill_cooldown = 0
end

function CallsDispatcher:onTick()
  self.tick = self.tick + 1
  -- Old saves may not have initialized _auto_fill_cooldown; default it here.
  self._auto_fill_cooldown = (self._auto_fill_cooldown or 0) - 1
  if self._auto_fill_cooldown <= 0 then
    self._auto_fill_cooldown = 50
    self:autoFillIdleRooms()
  end
end

function CallsDispatcher:addChangeCallback(callback, self_value)
  self.change_callback[callback] = self_value
end

function CallsDispatcher:removeChangeCallback(callback)
  self.change_callback[callback] = nil
end

function CallsDispatcher:onChange()
  for callback, self_value in pairs(self.change_callback) do
    callback(self_value)
  end
end

function CallsDispatcher:callForStaff(room)
  local missing = room:getMissingStaff(room:getRequiredStaffCriteria())
  local anyone_missed = false
  for attribute, count in pairs(missing) do
    anyone_missed = true
    for i = 1, count do
      self:callForStaffEachRoom(room, attribute, attribute .. i)
    end
  end
  local sound = room.room_info.call_sound
  if anyone_missed and sound and not room.sound_played then
    room.world.ui:playAnnouncement(sound, AnnouncementPriority.Normal)
    room.sound_played = true
  end
end

function CallsDispatcher:callForStaffEachRoom(room, attribute, key)
  if not key then
    key = "-"
  end
  local new_call = self:enqueue(
    room,
    key,
    _S.calls_dispatcher.staff:format(room.room_info.name, attribute),
    --[[persistable:call_dispatcher_staff_verification]] function(staff)
      return CallsDispatcher.verifyStaffForRoom(room, attribute, staff)
    end,
    --[[persistable:call_dispatcher_staff_priority]] function(staff)
      return CallsDispatcher.getPriorityForRoom(room, attribute, staff)
    end,
    --[[persistable:call_dispatcher_staff_execute]] function(staff)
      return CallsDispatcher.sendStaffToRoom(room, staff)
    end
  )
  return new_call
end

-- Call for repair
--!param urgent Announcement should be made
--!param manual This call should not trigger advisor for "your machine is failing"
--!param lock_room This is a minor maintence. Rooms needed not to be locked.
--  If urgent or manual is specified, lock_room will be true automatically
function CallsDispatcher:callForRepair(object, urgent, manual, lock_room)
  lock_room = manual or lock_room

  local call = {
    verification = --[[persistable:call_dispatcher_repair_verification]] function() return false end,
    priority = --[[persistable:call_dispatcher_repair_priority]] function() return 1 end,
    execute = --[[persistable:call_dispatcher_repair_execute]] function(staff) return CallsDispatcher.sendStaffToRepair(object, staff) end,
    object = object,
    key = "repair",
    description = _S.calls_dispatcher.repair:format(object.object_type.name),
    dispatcher = self,
    created = self.tick,
    assigned = nil,
    dropped = nil
  }

  object:setRepairingMode(lock_room and true or false)

  if not manual and urgent then
    object.hospital:giveAdvice({_A.warnings.machines_falling_apart})
  elseif object.hospital:countStaffOfCategory("Handyman", 1) == 0 then
    -- Advise about hiring Handyman
    object.hospital:giveAdvice({_A.warnings.machinery_damaged2})
  end

  if not self.call_queue[object] then
    self.call_queue[object] = {}
  end
  self.call_queue[object]["repair"] = call
  return call
end

function CallsDispatcher:callForWatering(plant)
  local call = {
    verification = --[[persistable:call_dispatcher_watering_verification]]function()
      return false end,
    priority = --[[persistable:call_dispatcher_watering_priority]] function()
      return 1 end,
    execute = --[[persistable:call_dispatcher_watering_execute]] function(staff) return CallsDispatcher.sendStaffToWatering(plant, staff) end,
    object = plant,
    key = "watering",
    description = _S.calls_dispatcher.watering:format(plant.tile_x, plant.tile_y),
    dispatcher = self,
    created = self.tick,
    assigned = nil,
    dropped = nil
  }
  if not self.call_queue[plant] then
    self.call_queue[plant] = {}
  end
  self.call_queue[plant]["watering"] = call
  return call
end

--[[ Queues a call for vaccination of a patient
  @param patient (Patient) the patient who wishes to be vaccinated
  @return call (table) the call which was queued ]]
function CallsDispatcher:callNurseForVaccination(patient)
  local call = {
    object = patient,
    key = "vaccinate",
    description = "Vaccinating patient at: " ..
        tostring(patient.tile_x) .. "," .. tostring(patient.tile_y),
    verification = --[[persistable:call_dispatcher_vaccinate_verification]] function(staff)
      return CallsDispatcher.verifyStaffForVaccination(patient, staff)
    end,
    priority = --[[persistable:call_dispatcher_vaccinate_priority]] function(staff)
      return CallsDispatcher.getPriorityForVaccination(patient,staff)
    end,
    execute = --[[persistable:call_dispatcher_vaccinate_execute]] function(staff)
      return CallsDispatcher.sendNurseToVaccinate(patient, staff)
    end,
    dispatcher = self,
    created = self.tick,
    assigned = nil,
    dropped = nil
  }
  if not self.call_queue[patient] then
    self.call_queue[patient] = {}
  end
  self.call_queue[patient]["vaccinate"] = call

  return call
end

--[[Determines if a member of staff is suitable to vaccinate a patient they
  must be a nurse and not busy or too far away.
  @param patient (Patient) the patient calling for vaccination
  @param staff (Staff) staff member to verify if suitable to vaccinate
  @return true if suitable for vaccination false otherwise (boolean) ]]
function CallsDispatcher.verifyStaffForVaccination(patient, staff)
  -- If staff is not a nurse, or nurse is busy, or patient is busy, cannot vaccinate.
  if staff.humanoid_class ~= "Nurse" or not staff:isIdle() or
      staff:getRoom() or patient:getRoom() then
    return false
  end

  -- Test proximity of staff and patient.
  local px,py = patient.tile_x, patient.tile_y
  local nx,ny = staff.tile_x, staff.tile_y

  -- If any of the nurse or the patient tiles are nil
  if not px or not py or not nx or not ny then return false end

  local x_diff = math.abs(px - nx)
  local y_diff = math.abs(py - ny)
  local test_radius = 5

  -- Test if the patient's room is still empty in case they are just entering
  -- a room when they call for a staff to vaccinate them
  return x_diff <= test_radius and y_diff <= test_radius
end

--[[ Determine which nurse has the highest priority to vaccinate a patient
  the patient should be easily reachable from the nurse
  @param patient (Patient) the patient calling for vaccination
  @param nurse (Staff, humanoid_class Nurse) the nurse to verify if they
  have priority to vaccinate
  @return score (Integer) lowest score has higher priority to vaccinate ]]
function CallsDispatcher.getPriorityForVaccination(patient, nurse)
  assert(nurse.humanoid_class == "Nurse")
  --Lower the priority "score" the more urgent it is
  --The closest nurse to the patient has the highest priority for vaccination
  --Any nurse who cannot reach the paitient suffers a priority penalty
  local score = 0
  local nil_penalty = 10000
  local x, y = patient.tile_x, patient.tile_y

  -- Nurses prefer to vaccinate the closest patient
  local distance =
    patient.world:getPathDistance(nurse.tile_x, nurse.tile_y, x, y)
  if distance then
    score = score + distance
  else
    score = score + nil_penalty
  end
  return score
end

--[[ Once a nurse has been verified and priority decided do the actions to
  perform the actually vaccination, delegated to Epidemic class (@see
  Epidemic:createVaccinationActions) @param patient (Patient) the patient calling
  for vaccination @param nurse (Staff, humanoid_class Nurse) the nurse to perform
  the vaccination actions ]]
function CallsDispatcher.sendNurseToVaccinate(patient, nurse)
  assert(nurse.humanoid_class == "Nurse")

  local epidemic = nurse.hospital.epidemic
  if epidemic then
    epidemic:createVaccinationActions(patient,nurse)
  else
    -- The epidemic may have ended before the call can be executed
    -- so just finish the call immediately
    CallsDispatcher.queueCallCheckpointAction(nurse)
    nurse:queueAction(AnswerCallAction())
    nurse:finishAction()
    patient.reserved_for = nil
  end
end


-- Enqueue the call
-- returns: True if the call is inserted and queued, but not served
--          False if the call is served right away, or has been queued and assigned
function CallsDispatcher:enqueue(object, key, description, verification, priority, execute)
  if self.call_queue[object] and self.call_queue[object][key] then
    -- already queued
    return self.call_queue[object][key].assigned and true or false
  elseif not self.call_queue[object] then
    self.call_queue[object] = {}
  end

  local call = {
    verification = verification,
    priority = priority,
    execute = execute,
    object = object,
    key = key,
    description = description,
    dispatcher = self,
    created = self.tick
  }
  self.call_queue[object][key] = call

  return not self:findSuitableStaff(call)
end

-- Find suitable (best) staff for working on a specific call
-- True
function CallsDispatcher:findSuitableStaff(call)
  if call.dropped then
    -- If a call was thought needed to be reinserted, but actually it was dropped...
    return
  end

  -- TODO: Preempt staff those even on_call already.
  --       Say - when an machine broke down, preempt the nearby handyman for repairing
  --         even if he was going to water a far away plant
  -- TODO: Doctor could go to other room with real needs, even there are patients queued up
  --       (think of emergency? or surgeons still in GP office?)
  local min_score = 2^30
  local min_staff = nil
  for _, e in ipairs(self.world.entities) do
    if class.is(e, Staff) then
      if e.humanoid_class ~= "Handyman" then
        local score = call.verification(e) and call.priority(e) or nil
        if score ~= nil and score < min_score then
          min_score = score
          min_staff = e
        end
      end
    end
  end

  if min_staff then
    if debug then CallsDispatcher.dumpCall(call, 'executed right away') end
    self:executeCall(call, min_staff)
    return true
  else
    if debug then CallsDispatcher.dumpCall(call, 'queued') self:dump(self.call_queue) end
    self:onChange()
    return false
  end
end

-- Find the best call for a staff to work on.
-- When a staff goes to meandering mode, it should call this function to look for new call
-- Return true if a call is answered. False if there is no suitable call waiting and the staff is really free.
function CallsDispatcher:answerCall(staff)
  local min_score = 2^30
  local min_call = nil
  assert(not staff.on_call, "Staff member looking for work while already answering a call.")
  assert(staff.hospital, "Staff should still be a member of the hospital to answer a call.")

  if staff.humanoid_class == "Handyman" then
   staff:searchForHandymanTask()
   return true
  end
  -- Find the call with the highest priority (smaller means more urgency)
  --   if the staff satisfy the criteria
  for _, queue in pairs(self.call_queue) do
    for _, call in pairs(queue) do
      local score = call.verification(staff) and call.priority(staff) or nil
      if score ~= nil then
        if call.assigned then -- already being assigned? Can it be preempted?
          local another_score = call.priority(call.assigned)
          if another_score <= score then
            score = nil
          end
        end
        if score ~= nil and score < min_score then
          min_score = score
          min_call = call
        end
      end
    end
  end

  if min_call then
    if debug then self:dump() CallsDispatcher.dumpCall(min_call, 'answered') end
    if min_call.assigned then
      CallsDispatcher.unassignCall(min_call)
    end
    -- Check if the object is still in the world, live and not destroy
    assert(min_call.object.tile_x or min_call.object.x, "An destroyed object still has requested in the dispatching queue. Please check the Entity:onDestroy function")
    self:executeCall(min_call, staff)
    return true
  end
  return false
end

-- Dump the current call table for debugging
function CallsDispatcher:dump()
  print("--- Queue ---")
  for _, queue in pairs(self.call_queue) do
    for _, call in pairs(queue) do
      CallsDispatcher.dumpCall(call, (call.assigned and 'assigned' or 'unassigned'))
    end
  end
  print("----")
end

function CallsDispatcher.dumpCall(call, message)
  if message ~= nil then
    message = ': ' .. message
  else
    message = ''
  end

  local call_obj = call.object

  local position = 'nowhere'
  if call_obj.tile_x then
    position = call_obj.tile_x .. ',' .. call_obj.tile_y
  end
  if call_obj.x then
    position = call_obj.x .. ',' .. call_obj.y
  end
  if(class.is(call_obj,Humanoid)) then
    print(call.key .. '@' .. position .. message)
  else
    print((call_obj.room_info and call_obj.room_info.id or call_obj.object_type.id) ..
        '-' .. call.key .. '@' .. position .. message)
  end
end

-- Add checkpoint action
-- All call execution method should add this action in appropriate place to signify
--   the job is finished.
-- A interrupt handler could be supplied if special handling is needed.
-- If not, the default would be reinsert the call into the queue
function CallsDispatcher.queueCallCheckpointAction(humanoid, interrupt_handler)
  interrupt_handler = interrupt_handler or CallsDispatcher.actionInterruptHandler
  return humanoid:queueAction(CallCheckPointAction(humanoid.on_call, interrupt_handler))
end

-- Default checkpoint interrupt handler
-- Reset the assigned status, and find an replacement staff
function CallsDispatcher.actionInterruptHandler(action, humanoid)
  if action.call.assigned == humanoid then
    action.call.assigned = nil
    humanoid.on_call = nil
    humanoid.world.dispatcher:findSuitableStaff(action.call)
  end
end

--! Called when a call is completed successfully.
function CallsDispatcher.onCheckpointCompleted(call)
  if not call.dropped and call.assigned then
    if debug then CallsDispatcher.dumpCall(call, "completed") end
    call.assigned.on_call = nil
    call.assigned = nil
    call.dispatcher:dropFromQueue(call.object, call.key)
  end
end

function CallsDispatcher:executeCall(call, staff)
  self:clearAutoFillForStaff(staff)
  assert(not call.assigned, "call to be executed is still assigned")
  assert(not call.dropped, "call to be executed is dropped")
  assert(not staff.on_call, "staff was on call and assigned to a new call")
  call.assigned = staff
  staff.on_call = call
  self:onChange()
  call.execute(staff)
end

-- Drop any call associated with the object (and/or key).
--
-- Expected to be called when the call is no longer needed
--   (like a machine that needed repaired were replaced),
--   or when the object is destroyed, etc.
function CallsDispatcher:dropFromQueue(object, key)
  if debug then self:dump() end
  if key and self.call_queue[object] then
    local call = self.call_queue[object][key]
    if call then
      call.dropped = true
      if call.assigned then
        CallsDispatcher.unassignCall(call)
      end
      self.call_queue[object][key] = nil
    end
  elseif self.call_queue[object] then
    for _, call in pairs(self.call_queue[object]) do
      call.dropped = true
      if call.assigned then
        CallsDispatcher.unassignCall(call)
      end
    end
    self.call_queue[object] = nil
  end
  self:onChange()
end

function CallsDispatcher.unassignCall(call)
  local assigned = call.assigned
  assert(assigned.on_call == call, "Unassigning call but the staff was not on call or a different call")
  call.assigned = nil
  assigned.on_call = nil
  assigned:setNextAction(AnswerCallAction())
end

function CallsDispatcher.verifyStaffForRoom(room, attribute, staff)
  if not staff:isIdle() or not staff:fulfillsCriterion(attribute) then
    return false
  end

  -- Staff is in another room, not usable.
  local current_room = staff:getRoom()
  if not staff.hospital.policies["staff_allowed_to_move"] and
      current_room and current_room ~= room then
    return false
  end

  return true
end

function CallsDispatcher.getPriorityForRoom(room, attribute, staff)
  local score = 0
  local x, y = room:getEntranceXY()

  -- Doctor prefer serving nearby rooms
  local distance = room.world:getPathDistance(staff.tile_x, staff.tile_y, x, y)
  if distance then
    score = score + distance
  end

  -- More people on the queue has to be served earlier
  if room.door.queue then
    score = score - room.door.queue:reportedSize() * 5 -- 5 is just a weighting scale
    if room.door.queue:hasEmergencyPatient() then
      score = score - 200000 -- Emergency on queue trumps
    end
  end

  -- Prefer the tirer staff (such that less chance to have "resting synchronization issue")
  score = score - staff:getAttribute("fatigue") * 40 -- 40 is just a weighting scale

  -- Prefer a wandering staff member over a staff member in a room
  if not staff:getRoom() then
    score = score - 50
  end

  -- TODO: Assign doctor with higher ability

  -- Room requires specilitist trumps over normal rooms
  if attribute == "Researcher" or attribute == "Psychiatrist" or attribute == "Surgeon" then
    score = score - 100000
  end

  return score
end

-- Clears any auto-fill bookkeeping for a staff member heading to an idle room.
function CallsDispatcher:clearAutoFillForStaff(staff)
  if not staff or not staff.auto_fill_room then
    return
  end
  local room = staff.auto_fill_room
  if self.auto_fill_rooms[room] == staff then
    self.auto_fill_rooms[room] = nil
  end
  staff.auto_fill_room = nil
end

local function missingStaffCount(missing)
  for _, count in pairs(missing) do
    if count then
      return true
    end
  end
  return false
end

-- Decide whether a room should be auto-filled by idle corridor staff.
function CallsDispatcher:shouldAutoFillRoom(room)
  if not room or not room.is_active or not room.hospital then
    return false
  end
  local categories = room.room_info.categories or {}
  -- Avoid auto-filling complex multi-staff surgery to prevent stuck surgeons / invalid states.
  -- if room.room_info.id == "operating_theatre" then
  --   return false
  -- end
  -- Clinics are treatment rooms in Theme Hospital data; include them as well.
  if not categories.diagnosis and not categories.treatment and not categories.clinics then
    return false
  end
  local missing = room:getMissingStaff(room:getRequiredStaffCriteria())
  if not missingStaffCount(missing) then
    return false
  end
  local assigned = self.auto_fill_rooms[room]
  if assigned and assigned.auto_fill_room == room and not assigned.on_call and not assigned.fired then
    return false
  end
  return true
end

-- Check if staff can be redirected for idle room coverage.
function CallsDispatcher:isAutoFillCandidate(staff)
  if not staff or staff.fired or staff.dead or staff.pickup or staff.on_call then
    return false
  end
  if staff.humanoid_class == "Handyman" or staff.humanoid_class == "Receptionist" then
    return false
  end
  if staff:getRoom() then
    return false
  end
  return staff:isIdle() and not staff.auto_fill_room
end

-- Send an idle staff member to a room without consuming dispatcher calls.
function CallsDispatcher:_sendStaffToIdleRoom(room, staff)
  self.auto_fill_rooms[room] = staff
  staff.auto_fill_room = room
  staff:setNextAction(room:createEnterAction(staff))
  staff:setDynamicInfoText(_S.dynamic_info.staff.actions.heading_for:format(room.room_info.name))
end

-- Every ~50 ticks, try to place idle corridor staff in empty diagnosis/treatment rooms.
function CallsDispatcher:autoFillIdleRooms()
  -- Old saves may not have this table; create on demand.
  self.auto_fill_rooms = self.auto_fill_rooms or {}
  local assignments_done = 0
  local assignments_cap = 5 -- avoid heavy scans each tick; spread work over time.  LSF
  self._auto_fill_room_cursor = self._auto_fill_room_cursor or 1
  for room, staff in pairs(self.auto_fill_rooms) do
    if not staff or staff.fired or staff.dead or staff.on_call or staff.pickup or staff.auto_fill_room ~= room
        or staff:getRoom() or not staff:isIdle() or staff.hospital ~= room.hospital then
      self.auto_fill_rooms[room] = nil
      if staff then
        staff.auto_fill_room = nil
      end
    end
  end

  local rooms = {}
  for _, room in pairs(self.world.rooms) do
    if self:shouldAutoFillRoom(room) then
      rooms[#rooms + 1] = room
    end
  end
  if #rooms == 0 then
    return
  end
  -- Rotate start to give all rooms a chance across ticks.
  local start = self._auto_fill_room_cursor
  local room_count = #rooms

  local candidates = {}
  for _, entity in ipairs(self.world.entities) do
    if class.is(entity, Staff) and self:isAutoFillCandidate(entity) then
      candidates[#candidates + 1] = entity
    end
  end
  if #candidates == 0 then
    return
  end

  for j = 0, room_count - 1 do
    if assignments_done >= assignments_cap then break end
    local idx = ((start - 1 + j) % room_count) + 1
    local room = rooms[idx]
    local missing = room:getMissingStaff(room:getRequiredStaffCriteria())
    local rx, ry = room:getEntranceXY(false)
    for attribute, count in pairs(missing) do
      local needed = count or 0
      while needed > 0 do
        local best_i, best_distance
        for i, staff in ipairs(candidates) do
          if staff and staff:fulfillsCriterion(attribute) and staff.hospital == room.hospital
              and staff.tile_x and staff.tile_y then
            local distance = self.world:getPathDistance(staff.tile_x, staff.tile_y, rx, ry)
            if distance and (not best_distance or distance < best_distance) then
              best_distance = distance
              best_i = i
            end
          end
        end
        if best_i then
          local staff = table.remove(candidates, best_i)
          self:_sendStaffToIdleRoom(room, staff)
          needed = needed - 1
          assignments_done = assignments_done + 1
          if assignments_done >= assignments_cap then
            return
          end
        else
          needed = 0
        end
      end
    end
  end
  self._auto_fill_room_cursor = ((start - 1 + room_count) % room_count) + 1
end

function CallsDispatcher.sendStaffToRoom(room, staff)
  if staff:getRoom() == room then
    room:onHumanoidLeave(staff)
    CallsDispatcher.queueCallCheckpointAction(staff, CallsDispatcher.staffActionInterruptHandler)
    room:onHumanoidEnter(staff)
  else
    staff:setNextAction(room:createEnterAction(staff))
    CallsDispatcher.queueCallCheckpointAction(staff, CallsDispatcher.staffActionInterruptHandler)
  end
  staff:setDynamicInfoText(_S.dynamic_info.staff.actions.heading_for:format(room.room_info.name))
end

function CallsDispatcher.staffActionInterruptHandler(action, humanoid)
  local call = action.call
  if not call then return end
  if call.assigned == humanoid then
    call.assigned = nil
    humanoid.on_call = nil
    if not call.dropped then
      humanoid.world.dispatcher:callForStaff(call.object)
    end
  end
end

--! 'execute' callback for repairing an object (eg a machine).
--!param object Object to repair.
--!param handyman Staff to use.
function CallsDispatcher.sendStaffToRepair(object, handyman)
  object:createHandymanActions(handyman)
end

--! 'execute' callback for watering a plant.
--!param plant Plant to give water.
--!param handyman Staff to use.
function CallsDispatcher.sendStaffToWatering(plant, handyman)
  plant:createHandymanActions(handyman)
end
