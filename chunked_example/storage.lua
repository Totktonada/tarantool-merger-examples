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
    box.schema.space.create('s')
    box.space.s:create_index('pk')

    if instance_name == 'storage_1' then
        box.space.s:insert({1, 'one'})
        box.space.s:insert({3, 'three'})
        box.space.s:insert({5, 'five'})
        box.space.s:insert({7, 'seven'})
        box.space.s:insert({9, 'nine'})
        box.space.s:insert({11, 'eleven'})
        box.space.s:insert({13, 'thirteen'})
        box.space.s:insert({15, 'fifteen'})
        box.space.s:insert({17, 'seventeen'})
        box.space.s:insert({19, 'nineteen'})
    else
        box.space.s:insert({2, 'two'})
        box.space.s:insert({4, 'four'})
        box.space.s:insert({6, 'six'})
        box.space.s:insert({8, 'eight'})
        box.space.s:insert({10, 'ten'})
        box.space.s:insert({12, 'twelve'})
        box.space.s:insert({14, 'fourteen'})
        box.space.s:insert({16, 'sixteen'})
        box.space.s:insert({18, 'eighteen'})
        box.space.s:insert({20, 'twenty'})
    end

    box.schema.user.grant('guest', 'read', 'space', 's')
end)

if instance_name == 'storage_1' then
    box.cfg({listen = 3301})
else
    box.cfg({listen = 3302})
end
