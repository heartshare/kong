local crud = require "kong.api.crud_helpers"
local responses = require "kong.tools.responses"
local cjson = require "cjson"

return {
  ["/cluster/"] = {
    GET = function(self, dao_factory)
      local serf = require("kong.cli.services.serf")(configuration)
      local res, err = serf:invoke_signal("members", { ["-format"] = "json" })
      if err then
        return responses.send_HTTP_INTERNAL_SERVER_ERROR(err)
      else
        local members = cjson.decode(res)
        local result = {
          data = {}
        }
        local members = cjson.decode(res).members
        result.total = #members
        for _, v in pairs(members) do
          table.insert(result.data, {
            name = v.name,
            address = v.addr,
            status = v.status
          })
        end
        return responses.send_HTTP_OK(result)
      end
    end,

    POST = function(self, dao_factory)
      local serf = require("kong.cli.services.serf")(configuration)
      if self.params.address then
        local _, err = serf:invoke_signal("join", { self.params.address })
        if err then
          return responses.send_HTTP_BAD_REQUEST(err)
        else
          return responses.send_HTTP_OK()
        end
      else
        return responses.send_HTTP_BAD_REQUEST("Missing \"address\"")
      end
    end
  },
  
  ["/cluster/events/"] = {
    POST = function(self, dao_factory)
      ngx.log(ngx.DEBUG, " received cluster event "..(self.params.type and self.params.type or "UNKNOWN"))
      
      local message_t = self.params

      -- The type is always upper case
      if message_t.type then
        message_t.type = string.upper(message_t.type)
      end

      -- If it's an update, load the new entity too so it's available in the hooks
      if message_t.type == events.TYPES.ENTITY_UPDATED then
        message_t.old_entity = message_t.entity
        message_t.entity = dao[message_t.collection]:find_by_primary_key({id=message_t.old_entity.id})
        if not message_t.entity then
          -- This means that the entity has been deleted immediately after an update in the meanwhile that
          -- the system was still processing the update. A delete invalidation will come immediately after
          -- so we can ignore this event
          return responses.send_HTTP_OK()
        end
      end
      
      -- Trigger event in the node
      events:publish(message_t.type, message_t)
      return responses.send_HTTP_OK()
    end
  }
}
