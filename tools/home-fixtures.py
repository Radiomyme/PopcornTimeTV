#!/usr/bin/env python3
# How PopcornTimeTests/Fixtures/Home was made: the answers of the Home's sources recorded on
# 2026-11-14 (anonymous GETs, about 14:40 UTC), trimmed to the fields HomeParse reads. Kept as
# the record of what was cut; run it again on new recordings to refresh the fixtures (the
# tests assert on titles and dates of that day: they change with the fixtures).
#
#   python3 -I tools/home-fixtures.py <recordings> <lookups> PopcornTimeTests/Fixtures/Home <top100>
#
# <recordings>: one file per request, named as below.
#   cm_movie_top.json               https://v3-cinemeta.strem.io/catalog/movie/top.json
#   cm_series_top.json              https://v3-cinemeta.strem.io/catalog/series/top.json
#   cm_series_year_2026.json        https://v3-cinemeta.strem.io/catalog/series/year/genre=2026.json
#   cm_calendar_videos.json         https://v3-cinemeta.strem.io/catalog/series/calendar-videos/calendarVideosIds=<ids>.json
#   yts_q2026_date_minr6.json       https://movies-api.accel.li/api/v2/list_movies.json?limit=50&query_term=2026&sort_by=date_added&minimum_rating=6
#   yts_2160_date.json              …/list_movies.json?limit=50&quality=2160p&sort_by=date_added
#   yts_q2026_dl.json               …/list_movies.json?limit=50&query_term=2026&sort_by=download_count
#   tvmaze_schedule_web_1113.json   https://api.tvmaze.com/schedule/web?date=2026-11-13
#   tvmaze_schedule_us_1113.json    https://api.tvmaze.com/schedule?country=US&date=2026-11-13
#   tvmaze_schedule_web_today.json  https://api.tvmaze.com/schedule/web?date=2026-11-14
#   apibay_top100_48h_208.json, apibay_top100_48h_207.json, apibay_top100_211.json
#                                   https://apibay.org/precompiled/data_top100_<list>.json
# <top100> (required): the Top 100 of HD movies and of HD episodes, the two rankings since the
#   Home read them (recorded on 2026-11-16, after the other answers: their titles are matched
#   against the lists of 11-14). It also holds the cards of Coyote vs. Acme and Buddy
#   (cm_meta_movie_<tt>.json), two of the movies' leading titles no list knows: without it the
#   fixtures would disagree.
#   apibay_top100_207.json          https://apibay.org/precompiled/data_top100_207.json
#   apibay_top100_208.json          https://apibay.org/precompiled/data_top100_208.json
#   The 48 h lists (tpb_48h_207.json, tpb_48h_208.json) are no longer asked: kept as the record
#   of what the shelves were, for the parser's tests and the tests of the change.
# The TMDB files of the same folder (tmdb_*.json, the streaming services) are not recordings:
#   tools/tmdb-fixtures.py writes them from the Cinemeta files this script writes.
# <lookups>: the cards of the rankings' titles no list had, recorded the same day.
#   cm_last_videos_top48h.json      https://v3-cinemeta.strem.io/catalog/series/last-videos/lastVideosIds=<12 ids>.json
#   cm_meta_movie_<tt>.json         https://v3-cinemeta.strem.io/meta/movie/<tt>.json (four ids)
import json, sys, datetime, os
if len(sys.argv) != 5:
    sys.exit("usage: home-fixtures.py <recordings> <lookups> <out> <top100>")
FEEDS, EXTRA, OUT, TOP100 = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
NOW = datetime.datetime(2026, 11, 14, 14, 40, tzinfo=datetime.timezone.utc)
def J(name): return json.load(open(os.path.join(FEEDS, name)))
def iso(t):
    try: return datetime.datetime.fromisoformat((t or "").replace("Z", "+00:00"))
    except Exception: return None
def short(text, n=90):
    text = text or ""
    return text if len(text) <= n else text[:n].rstrip() + "…"
def write(name, value):
    path = os.path.join(OUT, name)
    with open(path, "w") as f: json.dump(value, f, ensure_ascii=False, separators=(",", ":"))
    print("%-28s %6d B" % (name, os.path.getsize(path)))

def videos(meta, keep_old=False):
    out = []
    dated = sorted([(iso(v.get("released")), v) for v in meta.get("videos") or [] if iso(v.get("released"))], key=lambda t: t[0])
    aired = [t for t in dated if t[0] <= NOW and (t[1].get("season") or 0) > 0]
    coming = [t for t in dated if t[0] > NOW and (t[1].get("season") or 0) > 0]
    chosen = aired[-2:] + coming[:1]
    if keep_old: chosen = [t for t in dated if (t[1].get("season") or 0) == 0][:1] + aired[:1] + chosen
    last_aired = aired[-1][1] if aired else None
    for _, v in chosen:
        e = {"season": v.get("season"), "episode": v.get("episode"), "name": v.get("name"), "released": v.get("released")}
        if v.get("thumbnail") and v is last_aired: e["thumbnail"] = v["thumbnail"]
        out.append(e)
    return out

def cm(meta, with_videos=False, keep_old=False, described=True):
    out = {"id": meta["id"], "name": meta["name"], "type": meta.get("type")}
    for key in ("releaseInfo", "released", "imdbRating", "genres", "runtime", "poster", "background", "logo"):
        if meta.get(key) not in (None, "", []): out[key] = meta[key]
    if meta.get("description") and described: out["description"] = short(meta["description"])
    if meta.get("trailerStreams"): out["trailerStreams"] = [{"ytId": meta["trailerStreams"][0]["ytId"]}]
    if with_videos: out["videos"] = videos(meta, keep_old)
    return out

top = J("cm_movie_top.json")["metas"]
write("cm_movie_top.json", {"metas": [cm(m, described=i < 3) for i, m in enumerate(top[:20])], "hasMore": True})
series = J("cm_series_top.json")["metas"]
write("cm_series_top.json", {"metas": [cm(m, True, keep_old=i in (0, 17), described=i < 3) for i, m in enumerate(series[:20])], "hasMore": True})
year = J("cm_series_year_2026.json")["metas"]
# The first ten: dated, undated, and one bare stub (no poster) as the catalog has them.
picked = year[:10]
stub = dict(picked[2]); stub.pop("poster", None); picked[2] = stub
write("cm_series_year_2026.json", {"metas": [cm(m, True, described=i < 2) for i, m in enumerate(picked)]})
cal = J("cm_calendar_videos.json")["metasDetailed"]
def calendar(meta):
    out = cm(meta)
    dated = sorted([(iso(v.get("released")), v) for v in meta.get("videos") or [] if iso(v.get("released"))], key=lambda t: t[0])
    near = [v for d, v in dated if abs((d - NOW).days) <= 24][-6:] or [v for _, v in dated[-2:]]
    out["videos"] = [{"season": v.get("season"), "episode": v.get("episode"), "name": v.get("name"), "released": v.get("released"), **({"thumbnail": v["thumbnail"]} if v.get("thumbnail") else {})} for v in near]
    return out
write("cm_calendar.json", {"metasDetailed": [calendar(m) for m in cal if m["name"] in ("MobLand", "Nocturne", "Dexter: Resurrection", "Slow Horses", "Breaking Bad")]})

def yts(movie, rich):
    out = {"imdb_code": movie["imdb_code"], "title": movie["title"], "year": movie["year"], "rating": movie["rating"],
           "runtime": movie.get("runtime"), "genres": (movie.get("genres") or [])[:2], "language": movie.get("language"),
           "large_cover_image": movie.get("large_cover_image"), "date_uploaded_unix": movie.get("date_uploaded_unix"),
           "torrents": [{"quality": t["quality"]} for t in movie.get("torrents") or []]}
    if not rich: return out
    if movie.get("summary"): out["summary"] = short(movie["summary"], 70)
    if movie.get("yt_trailer_code"): out["yt_trailer_code"] = movie["yt_trailer_code"]
    if movie.get("background_image_original"): out["background_image_original"] = movie["background_image_original"]
    return out
def yts_file(name, source, count, must=()):
    movies = J(source)["data"]["movies"]
    chosen = movies[:count]
    for m in movies[count:]:
        if m["imdb_code"] in must: chosen.append(m)
    data = J(source)["data"]
    write(name, {"status": "ok", "status_message": "Query was successful",
                 "data": {"movie_count": data["movie_count"], "limit": 50, "page_number": 1, "movies": [yts(m, i < 3) for i, m in enumerate(chosen)]}})
yts_file("yts_new_2026.json", "yts_q2026_date_minr6.json", 30)
yts_file("yts_4k.json", "yts_2160_date.json", 21, must=("tt33764258", "tt29355505", "tt30825738"))
yts_file("yts_year_2026.json", "yts_q2026_dl.json", 30, must=("tt33764258", "tt41605854"))

def tvm_show(show):
    out = {"name": show["name"], "type": show.get("type"), "language": show.get("language"), "genres": show.get("genres"),
           "premiered": show.get("premiered"), "averageRuntime": show.get("averageRuntime"), "weight": show.get("weight"),
           "rating": {"average": (show.get("rating") or {}).get("average")}, "externals": {"imdb": (show.get("externals") or {}).get("imdb")},
           "image": {"original": (show.get("image") or {}).get("original")} if show.get("image") else None}
    if show.get("summary") and show.get("weight") == 100: out["summary"] = short(show["summary"], 60)
    return out
def tvm(ep, web):
    show = ep.get("show") or ep["_embedded"]["show"]
    out = {"name": ep.get("name"), "season": ep.get("season"), "number": ep.get("number"), "type": ep.get("type"),
           "airdate": ep.get("airdate"), "airstamp": ep.get("airstamp"), "runtime": ep.get("runtime"),
           "image": {"original": ep["image"]["original"]} if ep.get("image") else None}
    if web: out["_embedded"] = {"show": tvm_show(show)}
    else: out["show"] = tvm_show(show)
    return out
def tvm_file(name, source, web, wanted, extra):
    eps = J(source)
    def show(e): return e.get("show") or e["_embedded"]["show"]
    chosen = [e for e in eps if show(e)["name"] in wanted]
    seen = set()
    for label, test in extra:
        for e in eps:
            if id(e) not in seen and e not in chosen and test(e, show(e)):
                chosen.append(e); seen.add(id(e)); break
        else: print("   (no episode for: %s)" % label)
    write(name, [tvm(e, web) for e in chosen])
rejects = [
    ("no imdb", lambda e, s: not (s.get("externals") or {}).get("imdb")),
    ("special", lambda e, s: e.get("number") is None and (s.get("externals") or {}).get("imdb")),
    ("soap season", lambda e, s: (e.get("season") or 0) > 1900 and (s.get("externals") or {}).get("imdb")),
    ("low weight", lambda e, s: (s.get("weight") or 0) < 80 and (s.get("externals") or {}).get("imdb") and e.get("number")),
    ("other language", lambda e, s: s.get("language") not in ("English", "French", None) and (s.get("weight") or 0) >= 90 and (s.get("externals") or {}).get("imdb") and e.get("number") and s.get("type") == "Scripted"),
    ("news / talk", lambda e, s: s.get("type") in ("News", "Talk Show", "Reality") and (s.get("weight") or 0) >= 95 and (s.get("externals") or {}).get("imdb") and e.get("number") and (e.get("season") or 0) < 1900),
]
tvm_file("tvm_web_2026-11-13.json", "tvmaze_schedule_web_1113.json", True,
         ("Nocturne", "MobLand", "Tulsa King", "Dexter: Resurrection", "12 12 12", "Yaga", "Eternally Yours", "The Black Dagger Brotherhood"), rejects)
tvm_file("tvm_us_2026-11-13.json", "tvmaze_schedule_us_1113.json", False,
         ("Grey's Anatomy", "9-1-1", "Law & Order", "Elsbeth", "War", "Cupertino", "SpongeBob SquarePants", "Hell's Kitchen", "The Rainmaker", "Fire Country", "Sheriff Country"), rejects)
tvm_file("tvm_web_2026-11-14.json", "tvmaze_schedule_web_today.json", True, ("Honey", "The Proud Family: Louder and Prouder"),
         [("future", lambda e, s: (iso(e.get("airstamp")) or NOW) > NOW and (s.get("weight") or 0) >= 90 and (s.get("externals") or {}).get("imdb") and e.get("number") and s.get("language") == "English" and s.get("type") == "Scripted")])

def tpb(release):
    return {"name": release["name"], "category": release["category"], "seeders": release["seeders"],
            "added": release["added"], "imdb": release.get("imdb", "")}
write("tpb_48h_208.json", [tpb(r) for r in J("apibay_top100_48h_208.json")[:32]])
write("tpb_48h_207.json", [tpb(r) for r in J("apibay_top100_48h_207.json")[:30]])
write("tpb_211.json", [tpb(r) for r in J("apibay_top100_211.json")[:30]])
# 45 releases: 26 titles once the theater copies (9) and the releases without an id (7) are left out
# (the list's own minimum is 20).
write("tpb_207.json", [tpb(r) for r in json.load(open(os.path.join(TOP100, "apibay_top100_207.json")))[:45]])
# The whole list: 100 releases, 26 titles and 10 releases without an id (the list's own minimum is 10).
write("tpb_208.json", [tpb(r) for r in json.load(open(os.path.join(TOP100, "apibay_top100_208.json")))])

# Lookups of the rankings' titles no list knows: Cinemeta's last-videos (shows) and a movie meta.
def X(name): return json.load(open(os.path.join(EXTRA, name)))
# Six of the twelve shows asked: the test answers "unknown" for the others, as Cinemeta does
# for an id it does not have.
kept = ("tt0413573", "tt7235466", "tt0437005", "tt20859904", "tt36984433", "tt27954448")
last = X("cm_last_videos_top48h.json")["metasDetailed"]
write("cm_last_videos.json", {"metasDetailed": [cm(m, True, described=False) for m in last if m["id"] in kept]})
# file name -> answer, like Fixtures/Sources/cinemeta.json
metas = {}
for imdb in ("tt4154796", "tt27419420", "tt47791876", "tt29256561"):
    metas[imdb] = {"meta": cm(X("cm_meta_movie_%s.json" % imdb)["meta"], described=False)}
# The two unknown movies of the Top 100's leading titles (<top100>/cm_meta_movie_<tt>.json,
# recorded with it).
for imdb in ("tt1756855", "tt37281055"):
    metas[imdb] = {"meta": cm(json.load(open(os.path.join(TOP100, "cm_meta_movie_%s.json" % imdb)))["meta"], described=False)}
write("cm_meta_movies.json", metas)
