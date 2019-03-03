local fio = require('fio')
local fiber = require('fiber')

local vshard_cfg = {}

local UUID_LEN = 36

local function fio_read(filename)
    if not fio.path.exists(filename) then
        return nil
    end

    local fh = fio.open(filename, {'O_RDONLY'})
    if fh == nil then
        return nil
    end

    local res = fh:read(1024)
    fh:close()

    return res
end

local function check_uuid(uuid)
    assert(type(uuid) == 'string')
    if #uuid ~= UUID_LEN then
        return nil
    end
    return uuid
end

local function wait_uuid(filename)
    local uuid

    while uuid == nil do
        local data = fio_read(filename)
        if data ~= nil then
            uuid = check_uuid(data)
        end
        fiber.sleep(0.1)
    end

    return uuid
end

function vshard_cfg.wait_cfg()
    local instance_uuid_1 = wait_uuid('storage_1.instance.uuid')
    local instance_uuid_2 = wait_uuid('storage_2.instance.uuid')
    local cluster_uuid_1 = wait_uuid('storage_1.cluster.uuid')
    local cluster_uuid_2 = wait_uuid('storage_2.cluster.uuid')

    return {
        sharding = {
            [cluster_uuid_1] = {
                replicas = {
                    [instance_uuid_1] = {
                        uri = 'guest:@localhost:3301',
                        master = true,
                        name = 'storage_1',
                    }
                }
            },
            [cluster_uuid_2] = {
                replicas = {
                    [instance_uuid_2] = {
                        uri = 'guest:@localhost:3302',
                        master = true,
                        name = 'storage_2',
                    }
                }
            },
        }
    }
end

return vshard_cfg
