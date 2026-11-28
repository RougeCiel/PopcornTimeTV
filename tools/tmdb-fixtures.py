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
#
# The same run writes the answers of a title's page and a person's page (TMDBDetailClient:
# PopcornKit/Managers/Detail/TMDBDetailClient.swift) into the sibling folder TMDBDetail, read by
# PopcornTimeTests/Detail/TMDBDetailClientTests.swift. Hand-made too, with the same fake title ids
# and fake people (9300000 + n, made-up names, no real photo path):
#
#   find_<imdb id>.json                   /find/{imdb}: Halloween (movie 9100002), MobLand (show
#                                         9200000), a person by IMDb id (nm9300001 → 9300001)
#   find_tt0000404.json                   a title TMDB does not know (every list empty)
#   movie_9100002_recommendations.json    six movies of the Home's top, Halloween itself among them
#   movie_9100003_recommendations.json    none: the client asks the similar titles instead
#   movie_9100003_similar.json            three movies
#   tv_9200000_recommendations.json       three shows
#   movie_9100002_credits.json            a cast (one actor twice, as TMDB lists an actor with two
#                                         roles), a director, writers under several jobs, crew
#                                         that is neither (producer, story editor)
#   tv_9200000.json                       a show with ?append_to_response=aggregate_credits: its
#                                         creators, its cast with their roles, episode directors
#   person_9300001_combined_credits.json  a filmography: roles, a director's credit of a title
#                                         also played in, a talk show, « Himself », an undated
#                                         project, a show
#   external_ids.json                     "movie/9100002" → its IMDb id, for every title above
#                                         (the client asks /{movie|tv}/{id}/external_ids)
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

# ---- A title's page and a person's page (TMDBDetailClient) -----------------------------------
DETAIL = os.path.join(os.path.dirname(os.path.abspath(HOME)), "TMDBDetail")
os.makedirs(DETAIL, exist_ok=True)

def write_detail(name, value):
    path = os.path.join(DETAIL, name)
    with open(path, "w") as f: json.dump(value, f, ensure_ascii=False, separators=(",", ":"))
    print("TMDBDetail/%-38s %6d B" % (name, os.path.getsize(path)))

movies = results("cm_movie_top.json", "movie", 9100000)
shows = results("cm_series_top.json", "tv", 9200000)
external = {}
def listed(rows, kind):
    out = []
    for row in rows:
        external["%s/%d" % (kind, row["id"])] = row["imdb_id"]
        row = dict(row); del row["imdb_id"]          # TMDB's lists carry no IMDb id
        row["media_type"] = kind
        out.append(row)
    return out
def page(rows): return {"page": 1, "total_pages": 1, "total_results": len(rows), "results": rows}
def find(movie=(), tv=(), person=()):
    return {"movie_results": list(movie), "tv_results": list(tv), "person_results": list(person),
            "tv_episode_results": [], "tv_season_results": []}

halloween, mobland = movies[2], shows[0]
write_detail("find_%s.json" % halloween["imdb_id"], find(movie=listed([halloween], "movie")))
write_detail("find_%s.json" % movies[3]["imdb_id"], find(movie=listed([movies[3]], "movie")))
write_detail("find_%s.json" % mobland["imdb_id"], find(tv=listed([mobland], "tv")))
write_detail("find_nm9300001.json", find(person=[{"id": 9300001, "name": "Ada Fictional", "known_for_department": "Acting",
                                                   "profile_path": None, "adult": False, "gender": 1, "popularity": 12.5}]))
write_detail("find_tt0000404.json", find())
write_detail("movie_9100002_recommendations.json", page(listed(movies[4:9] + [halloween], "movie")))
write_detail("movie_9100003_recommendations.json", page([]))
write_detail("movie_9100003_similar.json", page(listed(movies[10:13], "movie")))
write_detail("tv_9200000_recommendations.json", page(listed(shows[1:4], "tv")))

def person(n, name, **extra):
    return dict({"adult": False, "gender": 2, "id": 9300000 + n, "known_for_department": "Acting", "name": name,
                 "original_name": name, "popularity": 10.0 - n / 10, "profile_path": None}, **extra)
write_detail("movie_9100002_credits.json", {"id": 9100002, "cast": [
    person(1, "Ada Fictional", cast_id=1, character="Laurie", credit_id="c1", order=0, profile_path="/ada.jpg"),
    person(2, "Ben Placeholder", cast_id=2, character="Dr. Loomis", credit_id="c2", order=1),
    person(1, "Ada Fictional", cast_id=3, character="Laurie (voice)", credit_id="c3", order=2, profile_path="/ada.jpg"),
    person(3, "Cy Sample", cast_id=4, character="", credit_id="c4", order=3),
], "crew": [
    person(10, "Dee Director", credit_id="d1", department="Directing", job="Director", known_for_department="Directing"),
    person(11, "Ed Writer", credit_id="w1", department="Writing", job="Screenplay", known_for_department="Writing"),
    person(11, "Ed Writer", credit_id="w2", department="Writing", job="Story", known_for_department="Writing"),
    person(10, "Dee Director", credit_id="w3", department="Writing", job="Writer", known_for_department="Directing"),
    person(12, "Flo Producer", credit_id="p1", department="Production", job="Producer"),
    person(13, "Gus Editor", credit_id="s1", department="Writing", job="Story Editor"),
]})
write_detail("tv_9200000.json", dict(listed([mobland], "tv")[0], created_by=[
    {"id": 9300020, "credit_id": "cr1", "name": "Hal Creator", "original_name": "Hal Creator", "gender": 2, "profile_path": "/hal.jpg"},
], aggregate_credits={"cast": [
    person(21, "Ivy Lead", roles=[{"credit_id": "r1", "character": "Maeve", "episode_count": 10}], total_episode_count=10, order=0),
    person(22, "Jon Support", roles=[{"credit_id": "r2", "character": "", "episode_count": 2},
                                     {"credit_id": "r3", "character": "Kevin", "episode_count": 1}], total_episode_count=3, order=1),
], "crew": [
    person(23, "Kim EpisodeDirector", department="Directing", jobs=[{"credit_id": "j1", "job": "Director", "episode_count": 2}],
           total_episode_count=2),
]}))

def credit(row, kind, **extra):
    entry = listed([row], kind)[0]
    entry.update(extra)
    return entry
write_detail("person_9300001_combined_credits.json", {"id": 9300001, "cast": [
    dict(credit(movies[5], "movie", character="Laurie", vote_count=900, credit_id="a1"), release_date="2025-11-14"),
    credit(movies[6], "movie", character="Sam", vote_count=4000, credit_id="a2"),
    credit(shows[2], "tv", character="Nina", vote_count=2500, episode_count=8, credit_id="a3"),
    credit(shows[3], "tv", character="Guest", vote_count=9000, episode_count=1, genre_ids=[10767], credit_id="a4"),
    credit(movies[7], "movie", character="Herself", vote_count=8000, credit_id="a5"),
    dict(credit(movies[8], "movie", character="Lead", vote_count=0, credit_id="a6"), release_date=""),
], "crew": [
    credit(movies[6], "movie", department="Directing", job="Director", vote_count=4000, credit_id="b1"),
    credit(movies[9], "movie", department="Directing", job="Director", vote_count=1500, credit_id="b2"),
    credit(movies[10], "movie", department="Production", job="Producer", vote_count=7000, credit_id="b3"),
]})
write_detail("external_ids.json", external)
