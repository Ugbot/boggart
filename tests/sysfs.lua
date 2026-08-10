-- sysfs.lua -- the libuv-backed filesystem primitives in src/lsys.c:
-- listdir/mkdir_p/stat/rmtree/home/shell. These replaced POSIX opendir/mkdir/
-- stat/getenv and a `rm -rf` shell-out, none of which exist on native Windows.
--
-- rmtree gets the most attention here: it is new, recursive, and destructive,
-- so its refusal guards and its symlink behaviour are worth pinning down.
local passed, failed = 0, 0
local function ok(cond, name)
  if cond then passed = passed + 1 else failed = failed + 1; io.write("FAIL: ", name, "\n") end
end
local function eq(a, b, name)
  if a == b then passed = passed + 1
  else failed = failed + 1; io.write("FAIL: ", name, " (", tostring(a), " ~= ", tostring(b), ")\n") end
end

local root = os.tmpname() .. "_boggart_sysfs"

-- ---- mkdir_p ----
ok(sys.mkdir_p(root .. "/a/b/c"), "mkdir_p creates nested dirs")
eq(sys.stat(root .. "/a/b/c"), "dir", "nested dir exists")
ok(sys.mkdir_p(root .. "/a/b/c"), "mkdir_p is idempotent on an existing dir")

-- trailing separators must not produce an empty final component
ok(sys.mkdir_p(root .. "/trail/"), "mkdir_p tolerates a trailing slash")
eq(sys.stat(root .. "/trail"), "dir", "trailing-slash dir created")

-- ---- stat ----
local f = io.open(root .. "/a/file.txt", "w"); f:write("hi"); f:close()
eq(sys.stat(root .. "/a/file.txt"), "file", "stat reports a regular file")
eq(sys.stat(root .. "/a"), "dir", "stat reports a directory")
eq(sys.stat(root .. "/does/not/exist"), nil, "stat returns nil for a missing path")

-- mkdir_p over an existing *file* must fail, not silently succeed
local mk, mkerr = sys.mkdir_p(root .. "/a/file.txt/nope")
eq(mk, nil, "mkdir_p fails through a non-directory component")
ok(type(mkerr) == "string", "mkdir_p returns an error string")

-- ---- listdir ----
local names = sys.listdir(root .. "/a")
table.sort(names)
eq(#names, 2, "listdir returns both entries")
eq(names[1], "b", "listdir entry 1")
eq(names[2], "file.txt", "listdir entry 2")
-- "." and ".." must never appear (uv_fs_scandir_next filters them)
local has_dot = false
for _, n in ipairs(names) do if n == "." or n == ".." then has_dot = true end end
ok(not has_dot, "listdir excludes . and ..")
eq(sys.listdir(root .. "/missing"), nil, "listdir returns nil for a missing dir")

-- ---- rmtree refusal guards ----
-- These are the paths where a bug upstream would otherwise be unrecoverable.
for _, bad in ipairs({ "/", "", ".", ".." }) do
  local r = sys.rmtree(bad)
  eq(r, nil, "rmtree refuses " .. string.format("%q", bad))
end

-- ---- rmtree must not follow a symlink out of the tree ----
-- Gated on caps.symlinks rather than on the OS: where symlinks need elevation
-- or Developer Mode, the *setup* would fail rather than the behaviour under
-- test. rmtree still uses lstat on every platform.
local caps = sys.caps()
local outside = os.tmpname() .. "_boggart_sysfs_outside"
sys.mkdir_p(outside)
local keep = io.open(outside .. "/keepme.txt", "w"); keep:write("precious"); keep:close()

if caps.symlinks then
  sys.exec(string.format("ln -s %q %q", outside, root .. "/a/link"), 10)
  eq(sys.stat(root .. "/a/link"), "dir", "symlink to a dir stats as dir (follows)")
end

ok(sys.rmtree(root), "rmtree removes the tree")
eq(sys.stat(root), nil, "tree is gone")
-- the crucial assertion: rmtree used lstat, so it unlinked the symlink rather
-- than descending through it and deleting the target's contents
eq(sys.stat(outside .. "/keepme.txt"), "file", "rmtree did NOT follow the symlink out")
sys.rmtree(outside)

-- ---- rmtree on an absent path is success, not an error ----
ok(sys.rmtree(root .. "/already/gone"), "rmtree treats ENOENT as success")

-- ---- home ----
local home = sys.home()
ok(type(home) == "string" and #home > 0, "home returns a non-empty string")
eq(sys.stat(home), "dir", "home is an existing directory")
-- uv_os_homedir must not leave the NUL/length mismatch that lua_pushlstring
-- would expose as a trailing garbage byte
eq(home, home:gsub("%z", ""), "home has no embedded NUL")

-- ---- shell ----
local exe, flag = sys.shell()
ok(type(exe) == "string" and #exe > 0, "shell exe is a non-empty string")
ok(type(flag) == "string" and #flag > 0, "shell flag is a non-empty string")
ok(sys.stat(exe) == "file" or caps.shell_kind == "cmd",
   "shell exe exists (or is the cmd.exe the platform names)")

-- ---- libuv is genuinely linked ----
ok(sys.uv_version():match("^%d+%.%d+%.%d+$") ~= nil, "uv_version looks like a version")

io.write(string.format("\n%d passed, %d failed\n", passed, failed))
return failed == 0 and 0 or 1
