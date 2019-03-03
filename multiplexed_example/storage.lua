#!/usr/bin/env tarantool

local fio = require('fio')

local instance_name = fio.basename(arg[0], '.lua')

box.cfg({
    wal_dir = instance_name,
    memtx_dir = instance_name,
    log = instance_name .. '.log',
    pid_file = instance_name .. '.pid',
    background = true,
})

box.once('init_storage', function()
    box.schema.space.create('a')
    box.schema.space.create('b')
    box.schema.space.create('c')
    box.schema.space.create('d')
    box.schema.space.create('e')
    box.space.a:create_index('pk')
    box.space.b:create_index('pk')
    box.space.c:create_index('pk')
    box.space.d:create_index('pk')
    box.space.e:create_index('pk')

    if instance_name == 'storage_1' then
        box.space.a:insert({1, 'a', 'one'})
        box.space.a:insert({3, 'a', 'three'})
        box.space.b:insert({5, 'b', 'five'})
        box.space.b:insert({7, 'b', 'seven'})
        box.space.c:insert({9, 'c', 'nine'})
        box.space.c:insert({11, 'c', 'eleven'})
        box.space.d:insert({13, 'd', 'thirteen'})
        box.space.d:insert({15, 'd', 'fifteen'})
        box.space.e:insert({17, 'e', 'seventeen'})
        box.space.e:insert({19, 'e', 'nineteen'})
    else
        box.space.a:insert({2, 'a', 'two'})
        box.space.a:insert({4, 'a', 'four'})
        box.space.b:insert({6, 'b', 'six'})
        box.space.b:insert({8, 'b', 'eight'})
        box.space.c:insert({10, 'c', 'ten'})
        box.space.c:insert({12, 'c', 'twelve'})
        box.space.d:insert({14, 'd', 'fourteen'})
        box.space.d:insert({16, 'd', 'sixteen'})
        box.space.e:insert({18, 'e', 'eighteen'})
        box.space.e:insert({20, 'e', 'twenty'})
    end

    box.schema.func.create('batch_select')

    box.schema.user.grant('guest', 'read', 'space', 'a')
    box.schema.user.grant('guest', 'read', 'space', 'b')
    box.schema.user.grant('guest', 'read', 'space', 'c')
    box.schema.user.grant('guest', 'read', 'space', 'd')
    box.schema.user.grant('guest', 'read', 'space', 'e')
    box.schema.user.grant('guest', 'execute', 'function', 'batch_select')
end)

-- Return N results in a table. Each result is a table of tuples.
local function batch_select(requests)
    local res = {}
    for _, space_name in ipairs(requests) do
        local tuples = box.space[space_name]:select()
        table.insert(res, tuples)
    end
    return res
end

-- Expose to call it using net.box.
_G.batch_select = batch_select

if instance_name == 'storage_1' then
    box.cfg({listen = 3301})
else
    box.cfg({listen = 3302})
end
