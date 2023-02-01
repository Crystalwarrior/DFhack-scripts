local dialogs = require('gui.dialogs')
local gui = require('gui')
local helpdb = require('helpdb')
local overlay = require('plugins.overlay')
local utils = require('utils')
local widgets = require('gui.widgets')

local PREFERENCES_INIT_FILE = 'dfhack-config/init/dfhack.control-panel-preferences.init'
local AUTOSTART_FILE = 'dfhack-config/init/onMapLoad.control-panel-new-fort.init'
local REPEATS_FILE = 'dfhack-config/init/onMapLoad.control-panel-repeats.init'

-- eventually this should be queryable from Core/script-manager
local FORT_SERVICES = {
    'autobutcher',
    'autochop',
    'autofarm',
    'autofish',
    'autoslab',
    'autounsuspend',
    'channel-safely',
    'emigration',
    'fastdwarf',
    'misery',
    'nestboxes',
    'prioritize',
    'seedwatch',
    'starvingdead',
    'tailor',
}

local FORT_AUTOSTART = {
    'ban-cooking all',
    --'buildingplan set boulders false',
    --'buildingplan set logs false',
}
for _,v in ipairs(FORT_SERVICES) do
    table.insert(FORT_AUTOSTART, v)
end
table.sort(FORT_AUTOSTART)

-- eventually this should be queryable from Core/script-manager
local SYSTEM_SERVICES = {
    'automelt', -- TODO needs dynamic detection of configurability
    'buildingplan',
    'overlay',
}

local PREFERENCES = {
    ['gui']={
        DEFAULT_INITIAL_PAUSE={type='bool', default=true,
         desc='Whether to pause the game when a DFHack tool is shown.'},
    },
    ['gui.widgets']={
        DOUBLE_CLICK_MS={type='int', default=500, min=50,
         desc='How long to wait for the second click of a double click, in ms.'},
        SCROLL_INITIAL_DELAY_MS={type='int', default=300, min=5,
         desc='The delay before scrolling quickly when holding the mouse button down on a scrollbar, in ms.'},
        SCROLL_DELAY_MS={type='int', default=20, min=5,
         desc='The delay between events when holding the mouse button down on a scrollbar, in ms.'},
    },
}

local REPEATS = {
    ['autoMilkCreature']={
        desc='Automatically milk creatures that are ready for milking.',
        command={'--time', '14', '--timeUnits', 'days', '--command', '[', 'workorder', '"{\\"job\\":\\"MilkCreature\\",\\"item_conditions\\":[{\\"condition\\":\\"AtLeast\\",\\"value\\":2,\\"flags\\":[\\"empty\\"],\\"item_type\\":\\"BUCKET\\"}]}"', ']'}},
    ['autoShearCreature']={
        desc='Automatically shear creatures that are ready for shearing.',
        command={'--time', '14', '--timeUnits', 'days', '--command', '[', 'workorder', 'ShearCreature', ']'}},
    ['cleanowned']={
        desc='Encourage dwarves to drop tattered clothing and grab new ones.',
        command={'--time', '1', '--timeUnits', 'months', '--command', '[', 'cleanowned', 'X', ']'}},
    ['orders-sort']={
        desc='Sort manager orders by repeat frequency so one-time orders can be completed.',
        command={'--time', '1', '--timeUnits', 'days', '--command', '[', 'orders', 'sort', ']'}},
    ['warn-starving']={
        desc='Show a warning dialog when units are starving or dehydrated.',
        command={'--time', '10', '--timeUnits', 'days', '--command', '[', 'warn-starving', ']'}},
}
local REPEATS_LIST = {}
for k in pairs(REPEATS) do
    table.insert(REPEATS_LIST, k)
end
table.sort(REPEATS_LIST)

-- save_fn takes the file as a param and should call f:write() to write data
local function save_file(path, save_fn)
    local ok, f = pcall(io.open, path, 'w')
    if not ok then
        dialogs.showMessage('Error',
            ('Cannot open file for writing: "%s"'):format(path))
        return
    end
    f:write('# DO NOT EDIT THIS FILE\n')
    f:write('# Please use gui/control-panel to edit this file\n\n')
    save_fn(f)
    f:close()
end


local function get_icon_pens()
    local start = dfhack.textures.getControlPanelTexposStart()
    local valid = start > 0
    start = start + 10

    local enabled_pen_left = dfhack.pen.parse{fg=COLOR_CYAN,
            tile=valid and (start+0) or nil, ch=string.byte('[')}
    local enabled_pen_center = dfhack.pen.parse{fg=COLOR_LIGHTGREEN,
            tile=valid and (start+1) or nil, ch=251} -- check
    local enabled_pen_right = dfhack.pen.parse{fg=COLOR_CYAN,
            tile=valid and (start+2) or nil, ch=string.byte(']')}
    local disabled_pen_left = dfhack.pen.parse{fg=COLOR_CYAN,
            tile=valid and (start+3) or nil, ch=string.byte('[')}
    local disabled_pen_center = dfhack.pen.parse{fg=COLOR_RED,
            tile=valid and (start+4) or nil, ch=string.byte('x')}
    local disabled_pen_right = dfhack.pen.parse{fg=COLOR_CYAN,
            tile=valid and (start+5) or nil, ch=string.byte(']')}
    local button_pen_left = dfhack.pen.parse{fg=COLOR_CYAN,
            tile=valid and (start+6) or nil, ch=string.byte('[')}
    local button_pen_right = dfhack.pen.parse{fg=COLOR_CYAN,
            tile=valid and (start+7) or nil, ch=string.byte(']')}
    local help_pen_center = dfhack.pen.parse{
            tile=valid and (start+8) or nil, ch=string.byte('?')}
    local configure_pen_center = dfhack.pen.parse{
            tile=valid and (start+9) or nil, ch=15} -- gear/masterwork symbol
    return enabled_pen_left, enabled_pen_center, enabled_pen_right,
            disabled_pen_left, disabled_pen_center, disabled_pen_right,
            button_pen_left, button_pen_right,
            help_pen_center, configure_pen_center
end
local ENABLED_PEN_LEFT, ENABLED_PEN_CENTER, ENABLED_PEN_RIGHT,
        DISABLED_PEN_LEFT, DISABLED_PEN_CENTER, DISABLED_PEN_RIGHT,
        BUTTON_PEN_LEFT, BUTTON_PEN_RIGHT,
        HELP_PEN_CENTER, CONFIGURE_PEN_CENTER = get_icon_pens()

--
-- ConfigPanel
--

ConfigPanel = defclass(ConfigPanel, widgets.Panel)
ConfigPanel.ATTRS{
    title='Untitled page',
    intro_text=DEFAULT_NIL,
    is_enableable=DEFAULT_NIL,
    is_configurable=DEFAULT_NIL,
    select_label='Toggle enabled',
}

function ConfigPanel:init()
    self:addviews{
        widgets.Panel{
            frame={t=0, b=7},
            autoarrange_subviews=true,
            autoarrange_gap=1,
            subviews={
                widgets.WrappedLabel{
                    frame={t=0},
                    text_to_wrap=self.intro_text,
                },
                widgets.FilteredList{
                    frame={t=5},
                    view_id='list',
                    on_select=self:callback('on_select'),
                    row_height=2,
                },
            },
        },
        widgets.WrappedLabel{
            view_id='desc',
            frame={b=4, h=2},
            auto_height=false,
        },
        widgets.HotkeyLabel{
            frame={b=2, l=0},
            label=self.select_label,
            key='SELECT',
            enabled=self.is_enableable,
            on_activate=self:callback('on_submit')
        },
        widgets.HotkeyLabel{
            view_id='show_help_label',
            frame={b=1, l=0},
            label='Show tool help or run commands',
            key='CUSTOM_CTRL_H',
            on_activate=self:callback('show_help')
        },
        widgets.HotkeyLabel{
            view_id='launch',
            frame={b=0, l=0},
            label='Launch config UI',
            key='CUSTOM_CTRL_G',
            enabled=self.is_configurable,
            on_activate=self:callback('launch_config'),
        },
    }
end

function ConfigPanel:onInput(keys)
    local handled = ConfigPanel.super.onInput(self, keys)
    if keys._MOUSE_L_DOWN then
        local list = self.subviews.list.list
        local idx = list:getIdxUnderMouse()
        if idx then
            local x = list:getMousePos()
            if x <= 2 then
                self:on_submit()
            elseif x >= 4 and x <= 6 then
                self:show_help()
            elseif x >= 8 and x <= 10 then
                self:launch_config()
            end
        end
    end
    return handled
end

function ConfigPanel:refresh()
    local choices = {}
    for _,choice in ipairs(self:get_choices()) do
        local command = choice.command or choice.target
        command = command:match('^([%S]+)')
        local gui_config = 'gui/' .. command
        local want_gui_config = utils.getval(self.is_configurable)
                and helpdb.is_entry(gui_config)
        local enabled = choice.enabled
        local function get_enabled_pen(enabled_pen, disabled_pen)
            if not utils.getval(self.is_enableable) then
                return gui.CLEAR_PEN
            end
            return enabled and enabled_pen or disabled_pen
        end
        local text = {
            {tile=get_enabled_pen(ENABLED_PEN_LEFT, DISABLED_PEN_LEFT)},
            {tile=get_enabled_pen(ENABLED_PEN_CENTER, DISABLED_PEN_CENTER)},
            {tile=get_enabled_pen(ENABLED_PEN_RIGHT, DISABLED_PEN_RIGHT)},
            ' ',
            {tile=BUTTON_PEN_LEFT},
            {tile=HELP_PEN_CENTER},
            {tile=BUTTON_PEN_RIGHT},
            ' ',
            {tile=want_gui_config and BUTTON_PEN_LEFT or gui.CLEAR_PEN},
            {tile=want_gui_config and CONFIGURE_PEN_CENTER or gui.CLEAR_PEN},
            {tile=want_gui_config and BUTTON_PEN_RIGHT or gui.CLEAR_PEN},
            ' ',
            choice.target,
        }
        local desc = helpdb.is_entry(command) and
                helpdb.get_entry_short_help(command) or ''
        table.insert(choices,
                {text=text, command=choice.command, target=choice.target, desc=desc,
                 search_key=choice.target, enabled=enabled,
                 gui_config=want_gui_config and gui_config})
    end
    local list = self.subviews.list
    local filter = list:getFilter()
    local selected = list:getSelected()
    list:setChoices(choices)
    list:setFilter(filter, selected)
    list.edit:setFocus(true)
end

function ConfigPanel:on_select(idx, choice)
    local desc = self.subviews.desc
    desc.text_to_wrap = choice and choice.desc or ''
    if desc.frame_body then
        desc:updateLayout()
    end
    if choice then
        self.subviews.launch.enabled = utils.getval(self.is_configurable)
                and not not choice.gui_config
    end
end

function ConfigPanel:on_submit()
    if not utils.getval(self.is_enableable) then return false end
    _,choice = self.subviews.list:getSelected()
    if not choice then return end
    local tokens = {}
    table.insert(tokens, choice.command)
    table.insert(tokens, choice.enabled and 'disable' or 'enable')
    table.insert(tokens, choice.target)
    dfhack.run_command(tokens)
    self:refresh()
end

function ConfigPanel:show_help()
    _,choice = self.subviews.list:getSelected()
    if not choice then return end
    dfhack.run_command('gui/launcher', (choice.command or choice.target) .. ' ')
end

function ConfigPanel:launch_config()
    if not utils.getval(self.is_configurable) then return false end
    _,choice = self.subviews.list:getSelected()
    if not choice or not choice.gui_config then return end
    dfhack.run_command(choice.gui_config)
end

--
-- Services
--

Services = defclass(Services, ConfigPanel)
Services.ATTRS{
    services_list=DEFAULT_NIL,
}

function Services:get_enabled_map()
    local enabled_map = {}
    local output = dfhack.run_command_silent('enable'):split('\n+')
    for _,line in ipairs(output) do
        local _,_,command,enabled_str,extra = line:find('%s*(%S+):%s+(%S+)%s*(.*)')
        if enabled_str then
            enabled_map[command] = enabled_str == 'on'
        end
    end
    return enabled_map
end

function Services:get_choices()
    local enabled_map = self:get_enabled_map()
    local choices = {}
    for _,service in ipairs(self.services_list) do
        table.insert(choices, {target=service, enabled=enabled_map[service]})
    end
    return choices
end

--
-- FortServices
--

FortServices = defclass(FortServices, Services)
FortServices.ATTRS{
    title='Fort',
    is_enableable=dfhack.world.isFortressMode,
    is_configurable=dfhack.world.isFortressMode,
    intro_text='These tools can only be enabled when you have a fort loaded,'..
                ' but once you enable them, they will stay enabled when you'..
                ' save and reload your fort. If you want them to be'..
                ' auto-enabled for new forts, please see the previous page.',
    services_list=FORT_SERVICES,
}

--
-- FortServicesAutostart
--

FortServicesAutostart = defclass(FortServicesAutostart, Services)
FortServicesAutostart.ATTRS{
    title='Autostart',
    is_enableable=true,
    is_configurable=false,
    intro_text='Tools that are enabled on this page will be auto-enabled for'..
                ' you when you start a new fort, using the default'..
                ' configuration. To see tools that are enabled right now in'..
                ' an active fort, please see the next page.',
    services_list=FORT_AUTOSTART,
}

function FortServicesAutostart:init()
    local enabled_map = {}
    local ok, f = pcall(io.open, AUTOSTART_FILE)
    if ok and f then
        for line in f:lines() do
            line = line:trim()
            if #line == 0 or line:startswith('#') then goto continue end
            local service = line:match('^on%-new%-fortress enable ([%S]+)$')
                    or line:match('^on%-new%-fortress (.+)')
            if service then
                enabled_map[service] = true
            end
            ::continue::
        end
    end
    self.enabled_map = enabled_map
end

function FortServicesAutostart:get_enabled_map()
    return self.enabled_map
end

function FortServicesAutostart:on_submit()
    _,choice = self.subviews.list:getSelected()
    if not choice then return end
    self.enabled_map[choice.target] = not choice.enabled

    local save_fn = function(f)
        for service,enabled in pairs(self.enabled_map) do
            if enabled then
                if service:match(' ') then
                    f:write(('on-new-fortress %s\n'):format(service))
                else
                    f:write(('on-new-fortress enable %s\n'):format(service))
                end
            end
        end
    end
    save_file(AUTOSTART_FILE, save_fn)
    self:refresh()
end

--
-- SystemServices
--

SystemServices = defclass(SystemServices, Services)
SystemServices.ATTRS{
    title='System',
    is_enableable=true,
    is_configurable=true,
    intro_text='These are DFHack system services that should generally not'..
                ' be turned off. If you do turn them off, they may'..
                ' automatically re-enable themselves when you restart DF.',
    services_list=SYSTEM_SERVICES,
}

--
-- Overlays
--

Overlays = defclass(Overlays, ConfigPanel)
Overlays.ATTRS{
    title='Overlays',
    is_enableable=true,
    is_configurable=true,
    intro_text='These are DFHack overlays that add information and'..
                ' functionality to various DF screens.',
}

function Overlays:get_choices()
    local choices = {}
    local state = overlay.get_state()
    for _,name in ipairs(state.index) do
        table.insert(choices, {command='overlay',
                               target=name,
                               enabled=state.config[name].enabled})
    end
    return choices
end

--
-- Preferences
--

IntegerInputDialog = defclass(IntegerInputDialog, widgets.Window)
IntegerInputDialog.ATTRS{
    visible=false,
    frame={w=50, h=8},
    frame_title='Edit setting',
    frame_style=gui.PANEL_FRAME,
    on_hide=DEFAULT_NIL,
}

function IntegerInputDialog:init()
    self:addviews{
        widgets.Label{
            frame={t=0, l=0},
            text={
                'Please enter a new value for ',
                {text=function() return self.id or '' end},
                NEWLINE,
                {text=self:callback('get_spec_str')},
            },
        },
        widgets.EditField{
            view_id='input_edit',
            frame={t=3, l=0},
            on_char=function(ch) return ch:match('%d') end,
        },
    }
end

function IntegerInputDialog:get_spec_str()
    if not self.spec or (not self.spec.min and not self.spec.max) then
        return ''
    end
    local strs = {}
    if self.spec.min then
        table.insert(strs, ('at least %d'):format(self.spec.min))
    end
    if self.spec.max then
        table.insert(strs, ('at most %d'):format(self.spec.max))
    end
    return ('(%s)'):format(table.concat(strs, ', '))
end

function IntegerInputDialog:show(id, spec, initial)
    self.visible = true
    self.id, self.spec = id, spec
    local edit = self.subviews.input_edit
    edit:setText(tostring(initial))
    edit:setFocus(true)
    self:updateLayout()
end

function IntegerInputDialog:hide(val)
    self.visible = false
    self.on_hide(tonumber(val))
end

function IntegerInputDialog:onInput(keys)
    if IntegerInputDialog.super.onInput(self, keys) then
        return true
    end
    if keys.SELECT then
        self:hide(self.subviews.input_edit.text)
        return true
    elseif keys.LEAVESCREEN or keys._MOUSE_R_DOWN then
        self:hide()
        return true
    end
end

Preferences = defclass(Preferences, ConfigPanel)
Preferences.ATTRS{
    title='Preferences',
    is_enableable=true,
    is_configurable=true,
    intro_text='These are the customizable DFHack system settings.',
    select_label='Edit setting',
}

function Preferences:init()
    self.subviews.show_help_label.visible = false
    self.subviews.launch.visible = false
    self:addviews{
        widgets.HotkeyLabel{
            frame={b=0, l=0},
            label='Restore defaults',
            key='CUSTOM_CTRL_G',
            on_activate=self:callback('restore_defaults')
        },
        IntegerInputDialog{
            view_id='input_dlg',
            on_hide=self:callback('set_val'),
        },
    }
end

function Preferences:onInput(keys)
    -- call grandparent's onInput since we don't want ConfigPanel's processing
    local handled = Preferences.super.super.onInput(self, keys)
    if keys._MOUSE_L_DOWN then
        local list = self.subviews.list.list
        local idx = list:getIdxUnderMouse()
        if idx then
            local x = list:getMousePos()
            if x <= 2 then
                self:on_submit()
            end
        end
    end
    return handled
end

function Preferences:refresh()
    if self.subviews.input_dlg.visible then return end
    local choices = {}
    for ctx_name,settings in pairs(PREFERENCES) do
        local ctx_env = require(ctx_name)
        for id,spec in pairs(settings) do
            local text = {
                {tile=BUTTON_PEN_LEFT},
                {tile=CONFIGURE_PEN_CENTER},
                {tile=BUTTON_PEN_RIGHT},
                ' ',
                id,
                ' (',
                tostring(ctx_env[id]),
                ')',
            }
            table.insert(choices,
                {text=text, desc=spec.desc, search_key=id,
                 ctx_env=ctx_env, id=id, spec=spec})
        end
    end
    local list = self.subviews.list
    local filter = list:getFilter()
    local selected = list:getSelected()
    list:setChoices(choices)
    list:setFilter(filter, selected)
    list.edit:setFocus(true)
end

local function preferences_set_and_save(self, choice, val)
    choice.ctx_env[choice.id] = val
    self:do_save()
    self:refresh()
end

function Preferences:on_submit()
    _,choice = self.subviews.list:getSelected()
    if not choice then return end
    if choice.spec.type == 'bool' then
        preferences_set_and_save(self, choice, not choice.ctx_env[choice.id])
    elseif choice.spec.type == 'int' then
        self.subviews.input_dlg:show(choice.id, choice.spec,
                                     choice.ctx_env[choice.id])
    end
end

function Preferences:set_val(val)
    _,choice = self.subviews.list:getSelected()
    if not choice or not val then return end
    preferences_set_and_save(self, choice, val)
end

function Preferences:do_save()
    local save_fn = function(f)
        for ctx_name,settings in pairs(PREFERENCES) do
            local ctx_env = require(ctx_name)
            for id in pairs(settings) do
                f:write((':lua require("%s").%s=%s\n'):format(
                        ctx_name, id, tostring(ctx_env[id])))
            end
        end
    end
    save_file(PREFERENCES_INIT_FILE, save_fn)
end

function Preferences:restore_defaults()
    for ctx_name,settings in pairs(PREFERENCES) do
        local ctx_env = require(ctx_name)
        for id,spec in pairs(settings) do
            ctx_env[id] = spec.default
        end
    end
    os.remove(PREFERENCES_INIT_FILE)
    self:refresh()
    dialogs.showMessage('Success', 'Default preferences restored.')
end

--
-- RepeatAutostart
--

RepeatAutostart = defclass(RepeatAutostart, ConfigPanel)
RepeatAutostart.ATTRS{
    title='Periodic',
    is_enableable=true,
    is_configurable=false,
    intro_text='Tools that can run periodically to fix bugs or warn you of'..
                ' dangers that are otherwise difficult to detect (like'..
                ' starving caged animals).',
}

function RepeatAutostart:init()
    self.subviews.show_help_label.visible = false
    self.subviews.launch.visible = false
    local enabled_map = {}
    local ok, f = pcall(io.open, REPEATS_FILE)
    if ok and f then
        for line in f:lines() do
            line = line:trim()
            if #line == 0 or line:startswith('#') then goto continue end
            local service = line:match('^repeat %-%-name ([%S]+)')
            if service then
                enabled_map[service] = true
            end
            ::continue::
        end
    end
    self.enabled_map = enabled_map
end

function RepeatAutostart:onInput(keys)
    -- call grandparent's onInput since we don't want ConfigPanel's processing
    local handled = RepeatAutostart.super.super.onInput(self, keys)
    if keys._MOUSE_L_DOWN then
        local list = self.subviews.list.list
        local idx = list:getIdxUnderMouse()
        if idx then
            local x = list:getMousePos()
            if x <= 2 then
                self:on_submit()
            end
        end
    end
    return handled
end

function RepeatAutostart:refresh()
    local choices = {}
    for _,name in ipairs(REPEATS_LIST) do
        local enabled = self.enabled_map[name]
        local text = {
            {tile=enabled and ENABLED_PEN_LEFT or DISABLED_PEN_LEFT},
            {tile=enabled and ENABLED_PEN_CENTER or DISABLED_PEN_CENTER},
            {tile=enabled and ENABLED_PEN_RIGHT or DISABLED_PEN_RIGHT},
            ' ',
            name,
        }
        table.insert(choices,
            {text=text, desc=REPEATS[name].desc, search_key=name,
             name=name, enabled=enabled})
    end
    local list = self.subviews.list
    local filter = list:getFilter()
    local selected = list:getSelected()
    list:setChoices(choices)
    list:setFilter(filter, selected)
    list.edit:setFocus(true)
end

function RepeatAutostart:on_submit()
    _,choice = self.subviews.list:getSelected()
    if not choice then return end
    self.enabled_map[choice.name] = not choice.enabled

    local save_fn = function(f)
        for name,enabled in pairs(self.enabled_map) do
            if enabled then
                f:write(('repeat --name %s %s\n'):format(name,
                        table.concat(REPEATS[name].command, ' ')))
            end
        end
    end
    save_file(REPEATS_FILE, save_fn)
    self:refresh()
end

--
-- ControlPanel
--

ControlPanel = defclass(ControlPanel, widgets.Window)
ControlPanel.ATTRS {
    frame_title='DFHack Control Panel',
    frame={w=55, h=36},
    resizable=true,
    resize_min={h=26},
}

function get_prev_page_idx(pages)
    local idx = pages:getSelected()
    if idx == 1 then
        return #pages.subviews
    end
    return idx - 1
end

function get_next_page_idx(pages)
    local idx = pages:getSelected()
    if idx == #pages.subviews then
        return 1
    end
    return idx + 1
end

function ControlPanel:init()
    local cur_page_title_fn = function()
        return self.subviews.pages:getSelectedPage().title
    end
    local prev_page_fn = function()
        self:set_page(get_prev_page_idx(self.subviews.pages))
    end
    local prev_page_title_fn = function()
        local pages = self.subviews.pages
        return pages.subviews[get_prev_page_idx(pages)].title
    end
    local next_page_fn = function()
        self:set_page(get_next_page_idx(self.subviews.pages))
    end
    local next_page_title_fn = function()
        local pages = self.subviews.pages
        return pages.subviews[get_next_page_idx(pages)].title
    end

    self:addviews{
        widgets.HotkeyLabel{
            frame={l=0, t=0},
            auto_width=true,
            key='KEYBOARD_CURSOR_LEFT_FAST',
            label=prev_page_title_fn,
            on_activate=prev_page_fn,
        },
        widgets.Label{
            frame={l=6, t=0, w=1},
            text_pen=COLOR_LIGHTGREEN,
            text=string.char(27),
        },
        widgets.HotkeyLabel{
            frame={r=0, t=0},
            auto_width=true,
            key='KEYBOARD_CURSOR_RIGHT_FAST',
            label=next_page_title_fn,
            on_activate=next_page_fn,
        },
        widgets.Label{
            view_id='right_arrow',
            frame={r=10, t=0, w=1},
            text_pen=COLOR_LIGHTGREEN,
            text=string.char(26),
        },
        widgets.Label{
            frame={t=1},
            auto_width=true,
            text={{text=cur_page_title_fn}},
        },
        widgets.Pages{
            view_id='pages',
            frame={t=3, l=0, b=0, r=0},
            subviews={
                FortServices{view_id='fort'},
                RepeatAutostart{view_id='repeat'},
                Overlays{view_id='overlays'},
                Preferences{view_id='prefs'},
                SystemServices{view_id='system'},
                FortServicesAutostart{view_id='autostart'},
            },
        },
    }

    self:refresh_page()
end

function ControlPanel:refresh_page()
    self.subviews.pages:getSelectedPage():refresh()
end

function ControlPanel:set_page(val)
    local pages = self.subviews.pages
    pages:setSelected(val)
    self.subviews.right_arrow.frame.r = 2 +
            #pages.subviews[get_next_page_idx(pages)].title
    self:refresh_page()
    self:updateLayout()
end

--
-- ControlPanelScreen
--

ControlPanelScreen = defclass(ControlPanelScreen, gui.ZScreen)
ControlPanelScreen.ATTRS {
    focus_path='control-panel',
}

function ControlPanelScreen:init()
    self:addviews{ControlPanel{}}
end

function ControlPanelScreen:onDismiss()
    view = nil
end

view = view and view:raise() or ControlPanelScreen{}:show()
