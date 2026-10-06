-- Lets tests require tools/bundle.lua
return dofile((arg[0]:match("^(.*)/tests/run%.lua$") or ".") .. "/tools/bundle.lua")
