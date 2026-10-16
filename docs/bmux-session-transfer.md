# Bmux checkpoint transfer

BMUX-98 supplies the shared C/Lua native transfer API. BMUX-99 adds Studio and
terminal controls using that API. There is no Python runtime or second terminal
execution owner.

## Session controls

In Studio, join a server layout, then click **Sessions** in the Bmux toolbar
or choose **Bmux → Sessions / import / export**. In terminal Bmux press
**Ctrl-B**, then **e**. Both provide:

- Export session to new file.
- Import checkpoint file as a new inactive saved session.
- Inspect a saved session, including after an uncertain import response.
- Refresh named-session status and recovery errors.

Studio uses its ordinary keyboard/mouse chooser and path suggestions. Terminal
Bmux accepts Up/Down or j/k and Enter, or e/i/c/r; Escape cancels the current
field, then closes the modal. Fields preserve complete Unicode graphemes and
wrap at narrow widths. Modal text/paste stays out of the underlying terminal.
See the [actual SDL Sessions chooser](images/bmux-session-controls.png).

Exports create private 0600 files and refuse to overwrite an existing path.
Imports read regular files up to 4 MiB; directories, symlinks and FIFOs are
rejected. Paths and bytes are bounded before validation. Studio retains a
submitted file path while another request is pending; press Enter again after
it finishes. No operation is automatically replayed.

An export contains the current layout, cwd, bounded plain output and Boggart
resume references. It contains no argv, environment, controller credentials,
queued input or approval tokens. The checkpoint format and 4 MiB bound are
defined in [checkpoints](bmux-checkpoints.md).

Import creates a **new named saved session**, leaving the attached server and
its processes running. Every imported shell and agent restart recipe is changed
to `saved`, on both the native client and server. The server acquires the same
SQLite owner guard used by startup and uses an absent-key compare/set; it cannot
overwrite an existing or corrupt checkpoint, or steal a live session's owner.
Choose a new name when the target exists.

Start the saved session explicitly on its own private socket:

```sh
./boggart serve --socket /private/path/imported.sock --bmux-session imported-name
./boggart bmux --socket /private/path/imported.sock
```

The socket's parent must be owned and private. Layout, cwd and output become
visible inactive previews; saved agents appear as stopped Fleet entries. Merely
saving or restarting this session never starts their processes. Launch a new
agent or terminal explicitly when you want to execute work.

## Native Lua API

```lua
local client = require('bmux.sessionclient').new {
  socket = private_socket,
  token = optional_token,
  host_id = joined_layout.host_id,
}
client:export(function(error, checkpoint_json) end)
client:status(function(error, persistence_status) end)
client:import('imported-name', checkpoint_json, function(error, receipt) end)
client:saved('imported-name', function(error, checkpoint_json) end)
client:close()
```

Transfer is single-flight. It pins the joined host, validates checkpoint data
and requires an exact inactive/name import acknowledgement. A lost, malformed
or uncertain import response disables further imports on that client. Use
`saved` to inspect the named checkpoint; observation never resubmits an import
or clears uncertainty. Rejoin explicitly before issuing another mutation.

## Control routes

| Method | Path | Effect |
| --- | --- | --- |
| GET | `/layout/checkpoint` | Export current server layout and runtime metadata |
| POST | `/layout/checkpoints/HOST/NAME` | Create a new inactive named checkpoint |
| GET | `/layout/checkpoints/HOST/NAME` | Read saved data, including after an uncertain POST |

POST takes raw checkpoint JSON, keeping the full document within the existing
4 MiB native transport budget without a second JSON envelope. `HOST` is the
current layout host identity. `NAME` is 1–128 ASCII letters, digits, underscores
or hyphens. Query parameters are rejected. Each route requires its ordinary
control capability; read-only layout/export credentials cannot import.

Successful import returns exactly:

```json
{"name":"imported-name","inactive":true,"restart_required":true}
```

An existing name, occupied/invalid owner or changed host returns 409. Invalid
checkpoint/name/query returns 400; store failures return 503. Invalid source
bytes never reach runtime restore or alter saved data.

Explicit corrupt-session recovery remains BMUX-97 work. The menus currently
report a blocked checkpoint and preserve its bytes; they do not clear it.
Start an imported named session explicitly as shown above, then join its socket
from either frontend to view its inactive saved output.
