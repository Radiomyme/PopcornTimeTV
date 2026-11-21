#!/usr/bin/env python3
# How the TMDB files of PopcornTimeTests/Fixtures/Home were made: HAND-MADE answers in TMDB's
# shape, not recordings (no TMDB key is used, and no request is made). They are written from the
# Cinemeta fixtures of the same folder (tools/home-fixtures.py), so every title is one the other
# recorded lists already know, under its real IMDb id; the TMDB ids are fake (9100000 + n for the
# movies, 9200000 + n for the shows: far above TMDB's own). Each result already has its "imdb_id",
# as TMDBStreamingClient hands a page to the hub; the client itself reads the external ids off
# the same pages (TMDBRecorded, PopcornKit/Managers/Providers/TMDBStreamingClient.swift).
#
#   python3 -I tools/tmdb-fixtures.py PopcornTimeTests/Fixtures/Home
#
#   tmdb_<movie|tv>_<popular|recent|topRated>_p<1|2>.json   the 20 popular movies / shows of
#                                                          cm_movie_top.json / cm_series_top.json in
#                                                          three orders, 12 then 8 per page
#   tmdb_providers.json                                     eight services, the most watched first
#                                                          (TMDB's provider ids and names)
#   tmdb_regions.json                                       nine countries
#
# The DEBUG launch argument -PTDebugHomeFixtures <folder> makes the app answer every TMDB request
# from these files: the hub's lists and the client's (grids, See All, Settings).
import json, os, sys
if len(sys.argv) != 2:
    sys.exit("usage: tmdb-fixtures.py <PopcornTimeTests/Fixtures/Home>")
HOME = sys.argv[1]
# Cinemeta's genres → TMDB's movie ids (the shows' differ: see TMDBStreamingClient.genreId).
GENRES = {"Action": 28, "Adventure": 12, "Animation": 16, "Comedy": 35, "Crime": 80, "Documentary": 99, "Drama": 18,
          "Family": 10751, "Fantasy": 14, "History": 36, "Horror": 27, "Mystery": 9648, "Romance": 10749, "Sci-Fi": 878,
          "Thriller": 53, "War": 10752, "Western": 37}

def write(name, value):
    path = os.path.join(HOME, name)
    with open(path, "w") as f: json.dump(value, f, ensure_ascii=False, separators=(",", ":"))
    print("%-28s %6d B" % (name, os.path.getsize(path)))

def results(source, kind, base):
    metas = json.load(open(os.path.join(HOME, source)))["metas"]
    rows = []
    for i, meta in enumerate(metas):
        date = (meta.get("released") or "")[:10]
        row = {"id": base + i, "imdb_id": meta["id"], "vote_average": float(meta.get("imdbRating") or 0),
               "vote_count": 500 + 10 * i, "genre_ids": [GENRES[g] for g in meta.get("genres", []) if g in GENRES],
               "original_language": "en"}
        if meta.get("description"): row["overview"] = meta["description"]
        if kind == "movie": row.update(title=meta["name"], release_date=date)
        else: row.update(name=meta["name"], first_air_date=date)
        rows.append(row)
    return rows

for kind, source, base in [("movie", "cm_movie_top.json", 9100000), ("tv", "cm_series_top.json", 9200000)]:
    rows = results(source, kind, base)
    dated = "release_date" if kind == "movie" else "first_air_date"
    orders = {"popular": rows, "recent": sorted(rows, key=lambda r: r[dated], reverse=True),
              "topRated": sorted(rows, key=lambda r: r["vote_average"], reverse=True)}
    for sort, ordered in orders.items():
        for page, chunk in [(1, ordered[:12]), (2, ordered[12:])]:
            write("tmdb_%s_%s_p%d.json" % (kind, sort, page),
                  {"page": page, "total_pages": 2, "total_results": len(ordered), "results": chunk})

providers = [(8, "Netflix"), (119, "Amazon Prime Video"), (337, "Disney Plus"), (381, "Canal+"), (350, "Apple TV+"),
             (531, "Paramount Plus"), (1899, "Max"), (56, "OCS")]
write("tmdb_providers.json", {"results": [{"provider_id": i, "provider_name": n, "display_priority": p + 1,
                                           "display_priorities": {"FR": p + 1, "US": p + 1}}
                                          for p, (i, n) in enumerate(providers)]})
write("tmdb_regions.json", {"results": [{"iso_3166_1": c} for c in ["FR", "BE", "CH", "CA", "US", "GB", "DE", "ES", "IT"]]})
