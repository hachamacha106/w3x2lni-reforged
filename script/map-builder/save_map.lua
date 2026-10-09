local lang = require 'share.lang'

return function (w2l, w3i, w3f, input_ar, output_ar, args)
    local closed, close_error = input_ar:close()
    if closed == false then
        w2l:failed(close_error or 'Cannot close input archive')
    end
    if w2l.setting.mode == 'lni' then
        output_ar:flush()
    end
    local suc, res = output_ar:save(w3i, w3f, w2l, args)
    if not suc then
        output_ar:close()
        w2l:failed(res or lang.script.CREATE_FAILED)
    end
    closed, close_error = output_ar:close()
    if closed == false then
        w2l:failed(close_error or 'Cannot finish output archive')
    end
end
