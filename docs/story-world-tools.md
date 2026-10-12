# World lookup tools: where things are, and whether a claim is true

Code, not a model. These answer "where is X", "is X inside Y", "can they get there in
time", "is this true in the book" straight from the story model
([story-model.md](story-model.md)): the place tree, canon `move` deltas, holdings, facts.
Nothing here asks a model anything.

Code: `lua/story/geo.lua` (the lookups), `lua/story/geotool.lua` (the `geo` and `check`
nouns of the `story` tool), skills `world_check` and `world_lookup`.
Tests: `tests/story_geo.lua`.

## Three answers, never a guess

Every verdict is **TRUE**, **FALSE** or **UNKNOWN**.

- **UNKNOWN** means the book does not say. "No record" is never reported as false, and the
  model is told not to fill the gap from plausibility.
- **FALSE** always names the record that makes it false (the container chain, the event, the
  holder).
- **TRUE** cites its evidence the same way (`evidence: E1 (t=1): Vera sits in the cafe`).

## The data it reads

Nothing new has to be modelled to start. A place is an entity of kind `place`; `parent` is
the container (Cafe Lune → Paris → France → Europe). People and things get a location from
canon `move` events (`move vera to cafe-lune`); an item with a holder is where its holder
is; anything else with only a place as its `parent` is "at home" there.

Optional geography goes on the place (`geo set`): `lat`/`lon` for straight-line distance, and
routes (`route_to=` another place with `days=`, `mode=`, `one_way=true`). A place with neither
borrows the nearest container that has them, so a cafe in Paris travels as Paris does.

## `geo` (look things up)

| action | asks |
|---|---|
| `geo where name= as_of=` | its place and every container around it: `Cafe Lune > Paris > France > Europe`, and the event that put it there |
| `geo inside name= of= as_of=` | is it within that place, at any depth |
| `geo contents name=<place> as_of= [deep=false] [kind=]` | who and what is there, nested places included |
| `geo tree [name=<place>]` | the place hierarchy |
| `geo between name= other= as_of=` | the smallest place two things share |
| `geo distance name= other=` | km between two places (needs coordinates) |
| `geo travel name=<who or place> to=<place> [t1= t2=] [per_day=] [speed=]` | the shortest declared route in days; with `t1`/`t2`, whether the journey fits. A traveller is measured from where they were at `t1` |
| `geo set name=<place> lat= lon=` or `route_to= days=` | store geography. The author's `/story` applies it; the model's call becomes a proposal |

`t` is in days unless `per_day=` says how many story-time units make a day. With no declared
route, `speed=` (km/day) gives a straight-line **lower bound**; without it the answer is
UNKNOWN, not "impossible".

## `check` (verify)

| action | verifies |
|---|---|
| `check claim claim="vera in paris" as_of=` | one plain-text claim, below |
| `check facts name= as_of= [pos=]` | the canon facts about it; `pos=` hides what is withheld until later in the telling and says how many are hidden |
| `check world` | the whole-world audit, below |
| `check travel …` | same as `geo travel` |

Claims it reads:

```
vera in paris           vera is at the cafe      (inside, any depth, by name or alias)
vera holds the key      vera has the key
moth alive              moth dead
vera mood=calm          vera trust >= 3          (state fields and relation values)
vera knows F3           (a character's knowledge of a fact id)
```

## `check world`: the audit

Deterministic, over the whole book, each finding with its severity and the events behind it:

- the place tree: a place inside itself, a parent that does not exist, a place inside a
  non-place
- geography data: coordinates out of range, a route to something that is not a place,
  negative days
- the event stream replayed in time order: a move to something that is not a place; **two
  places at once** (two moves at the same story time); **teleporting** (two moves closer in
  time than the shortest declared route allows); an item acquired while someone else still
  holds it; acting after `end`; deltas naming entities that do not exist

Teleport checks only fire where the book gives the data to decide (routes, or coordinates
plus `speed=`). Where it does not, the check stays silent rather than guessing.

## Skills

Both are code-driven in the repo's skill shape (`before`/`instructions`/`verify`):

- **`world_check`**: `before` runs the audit and puts it in front of the model;
  `verify` re-runs it and blocks "the world is consistent" while any error remains. Use
  before drafting a scene that moves people, and before calling a chapter done.
- **`world_lookup`**: `before` loads the place map so the model picks real names;
  `instructions` map each kind of question to the right call and say what UNKNOWN means.

## From a shell or the TUI

```
/story geo where name=Vera as_of=2
/story check claim claim="Vera in Paris" as_of=2
boggart story check world book=~/novel
```

## Not done (deliberately)

- **Free-text prose is not parsed for place mentions.** The lookups answer questions about the
  model; checking a draft's sentences against it is the extraction work in the story-model
  roadmap (M4), which would feed this.
- **Map rendering** and **region polygons** (is a point inside a country's border) are out: the
  containment tree is the authority, and coordinates are only for distance.

## SQL: the world as tables

The story model already lives in SQLite, so geography is queryable directly
(`lua/story/geosql.lua`, `src/ldb.c`). Everything is derived from the model; nothing is
a second copy except the R*Tree, which is only an index and is rebuilt on each `nearby`.

| name                | what                                                               |
|---------------------|--------------------------------------------------------------------|
| `geo_km(a,b,c,d)`   | SQL function: great-circle km between (lat1,lon1) and (lat2,lon2)  |
| `geo_bearing(...)`  | SQL function: initial bearing, degrees 0..360                      |
| `st_place`          | `book,id,name,parent,lat,lon` (own coordinates)                    |
| `st_place_geo`      | `book,id,lat,lon`: own coordinates, else the nearest container's   |
| `st_place_closure`  | `book,ancestor,descendant,depth`: every container, any depth       |
| `st_route`          | `book,src,dst,days,mode`: declared routes (two-way unless one_way) |
| `st_place_rt`       | R*Tree over `st_place_geo` (bounding-box search)                   |

```
geo nearby name=Paris km=500             places within a radius, nearest first, with bearing
geo nearby lat=45 lon=5 km=100           ... of a point
geo sql query="SELECT p.name, geo_km(a.lat,a.lon,p.lat,p.lon) AS km
               FROM st_place_geo a, st_place_geo p
               WHERE a.book=:book AND p.book=:book AND a.id='paris' ORDER BY km"
```

`geo sql` takes one `SELECT` / `WITH ... SELECT`, capped at 50 rows (`limit=`). Write
`book = :book` to scope to the current book. It refuses any write or DDL keyword and
more than one statement. Places with no coordinates, here or in a container, are absent
from `st_place_geo` and so from `nearby`: unknown, not far away.
