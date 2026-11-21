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
#   tmdb_providers.json                                     the services of a country (France): the
#                                                          most watched first, TMDB's provider ids
#                                                          and names as TMDB gave them on 2026-11-21,
#                                                          two stores among them (Apple TV Store,
#                                                          Amazon Video: rentals and purchases, which
#                                                          Settings leaves out)
#   tmdb_providers_US.json                                  the same in the United States, where Amazon
#                                                          Prime Video is provider 9 (119 elsewhere)
#   tmdb_regions.json                                       nine countries
#   tmdb_movie_popular_p3.json                              past the last page: six titles no
#                                                          other page has
#   tmdb_empty.json                                         an empty last page: every list of
#                                                          TMDBRecorded.emptyService (Apple TV)
#
# The fields are TMDB's, with TMDB's types, as its real answers have them (checked against TMDB on
# 2026-11-21): every field of a result is there, the ones the app does not read too. No real path
# is copied: "poster_path", "backdrop_path" and the providers' "logo_path" are null (TMDB has null
# for a title without artwork), so a fixture run shows Metahub's artwork and the services' names.
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
        row = {"adult": False, "backdrop_path": None, "id": base + i, "imdb_id": meta["id"],
               "vote_average": float(meta.get("imdbRating") or 0), "vote_count": 500 + 10 * i,
               "genre_ids": [GENRES[g] for g in meta.get("genres", []) if g in GENRES],
               "original_language": "en", "overview": meta.get("description") or "",
               "popularity": round(400.0 - 15 * i, 3), "poster_path": None, "softcore": False}
        if kind == "movie": row.update(title=meta["name"], original_title=meta["name"], release_date=date, video=False)
        else: row.update(name=meta["name"], original_name=meta["name"], first_air_date=date, origin_country=["US"])
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

def providers_of(region, providers):
    return {"results": [{"display_priorities": {region: p}, "display_priority": p, "logo_path": None, "provider_name": n,
                         "provider_id": i} for p, (i, n) in enumerate(providers)]}

write("tmdb_providers.json", providers_of("FR", [
    (8, "Netflix"), (119, "Amazon Prime Video"), (350, "Apple TV"), (337, "Disney Plus"), (2, "Apple TV Store"),
    (381, "Canal+"), (283, "Crunchyroll"), (531, "Paramount Plus"), (1899, "HBO Max"), (10, "Amazon Video")]))
write("tmdb_providers_US.json", providers_of("US", [
    (8, "Netflix"), (9, "Amazon Prime Video"), (350, "Apple TV"), (337, "Disney Plus"), (15, "Hulu"), (10, "Amazon Video"),
    (2, "Apple TV Store"), (283, "Crunchyroll"), (1899, "HBO Max")]))
COUNTRIES = [("FR", "France"), ("BE", "Belgium"), ("CH", "Switzerland"), ("CA", "Canada"), ("US", "United States of America"),
             ("GB", "United Kingdom"), ("DE", "Germany"), ("ES", "Spain"), ("IT", "Italy")]
write("tmdb_regions.json", {"results": [{"iso_3166_1": c, "english_name": n, "native_name": n} for c, n in COUNTRIES]})
# A page past the last one (page 2 says total_pages 2): titles of its own (the shows of
# cm_series_top.json, under movie ids of their own), so a grid that asks past TMDB's last page
# shows them (StreamingServicesUITests).
beyond = [dict(row, id=9100900 + i, title=row["name"], original_title=row["name"], release_date=row["first_air_date"], video=False)
          for i, row in enumerate(results("cm_series_top.json", "tv", 0)[:6])]
for row in beyond: del row["name"], row["original_name"], row["first_air_date"], row["origin_country"]
write("tmdb_movie_popular_p3.json", {"page": 3, "total_pages": 3, "total_results": 26, "results": beyond})
write("tmdb_empty.json", {"page": 1, "total_pages": 1, "total_results": 0, "results": []})
