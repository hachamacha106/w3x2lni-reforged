-- Fields without ordinary binary object storage (for example current :de art
-- variants and alternate skin names) still need game-readable native output.
-- Route only fields observed in the selected dataset's native profiles.
return function(w2l, slk, options)
    options = options or {}
    local routes = {}
    local owners = {}
    local profile_kinds = {}
    local mapped_fields = {}
    local consumed = w2l.force_slk or w2l.setting.read_slk
    local groups = options.localization_only
        and {w2l.info.profile_strings or {}}
        or {w2l.info.profile_skin or {}, w2l.info.profile_strings or {}}
    for _, profiles in ipairs(groups) do
        for kind, filenames in pairs(profiles) do
            local fields = routes[kind] or {}
            routes[kind] = fields
            for _, filename in ipairs(filenames) do
                for _, field in ipairs(w2l:keydata()[filename] or {}) do
                    fields[field] = fields[field] or filename
                    profile_kinds[filename] = profile_kinds[filename] or {}
                    profile_kinds[filename][kind] = true
                end
            end
        end
    end
    for kind, fields in pairs(routes) do
        if next(fields) then
            mapped_fields[kind] = {}
            for _, meta in pairs(w2l:metadata()[kind]) do
                if meta.profile then mapped_fields[kind][meta.key] = true end
            end
            for id, obj in pairs(slk[kind] or {}) do
                if not w2l.setting.remove_unuse_object or obj._mark then
                    local name = id:lower()
                    owners[name] = owners[name] or {}
                    owners[name][kind] = obj
                end
            end
        end
    end
    local updates = {}
    local default_txt = w2l:get_default().txt or {}
    for name, extra in pairs(slk.txt or {}) do
        local kinds = owners[name]
        -- OBJ/LNI cleanup removes values equal to the stock record, including
        -- skinType. The remaining changed skin name still has the same owner.
        local skin_types = extra.skintype or default_txt[name] and default_txt[name].skintype
        local skin_type = skin_types and skin_types[1]
        if skin_type and routes[skin_type] then
            kinds = {[skin_type] = true}
        end
        if kinds then
            for key, values in pairs(extra) do
                if key:sub(1, 1) ~= '_' then
                    local destination
                    for kind in pairs(kinds) do
                        local fields = routes[kind]
                        local filename = fields[key] or fields[key:match '^[^:]+']
                        if filename then
                            assert(not destination or destination == filename,
                                ('Ambiguous native profile field %s.%s; preserve distinct object IDs or explicit skinType.'):format(name, key))
                            destination = filename
                        end
                    end
                    if destination then
                        updates[destination] = updates[destination] or {}
                        updates[destination][name] = updates[destination][name] or {}
                        updates[destination][name][key] = values
                    end
                end
            end
        end
    end
    local files = {}
    local filenames = {}
    for filename in pairs(updates) do filenames[filename] = true end
    if consumed then
        for filename in pairs(profile_kinds) do filenames[filename] = true end
    end
    for filename in pairs(filenames) do
        local original = w2l:file_load('map', filename)
        local existing = w2l:parse_txt(original or '')
        local changed = updates[filename] ~= nil
        if consumed and original then
            for name, fields in pairs(existing) do
                for kind, obj in pairs(owners[name] or {}) do
                    if profile_kinds[filename][kind] then
                        local mapped = mapped_fields[kind]
                        local private = w2l:metadata()[obj._code]
                        for key in pairs(fields) do
                            if mapped[key] then
                                fields[key] = nil
                                changed = true
                            elseif private then
                                for _, meta in pairs(private) do
                                    if type(meta) == 'table' and meta.profile and meta.key == key then
                                        fields[key] = nil
                                        changed = true
                                        break
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
        local objects = updates[filename] or {}
        for name, fields in pairs(objects) do
            existing[name] = existing[name] or {}
            for key, values in pairs(fields) do existing[name][key] = values end
        end
        if changed then
            files[filename] = w2l:backend_extra_txt(existing, slk, {
                preserve_unmarked = true, preserve_empty = true,
            })
        end
    end
    return files
end
