local fs = require 'bee.filesystem'

-- This is an input-kind check for the GUI. Archive integrity and lossless
-- eligibility are still verified independently by the backend.
return {
    packed = function(path)
        if not path or path:filename():string():lower() == '.w3x' then return false end
        local extension = path:extension():string():lower()
        return (extension == '.w3x' or extension == '.w3m') and fs.is_regular_file(path)
    end,
}
