# Recipe: structured bug fix iteration

The single highest-leverage pattern. Tests fail. You map each failure to a file + fix, hand it to maestrode, apply the result, run tests, iterate.

## The brief shape

```
TASK: fix 2 cross-file bugs.

FAIL: test_validation_empty_name
ASSERT: r.status_code == 422
GOT: 200
EXPECTED: 422
SUSPECT: backend/models.py (Pydantic validator)
FIX: add Field(min_length=1) on the name field

FAIL: test_normalize_strips_default_port_http
ASSERT: normalize('http://x:80/p') == 'http://x/p'
GOT: 'http://x:80/p'
EXPECTED: 'http://x/p'
SUSPECT: backend/util/normalize.py (no port-strip logic)
FIX: when scheme==http and port==80, set port to None before constructing netloc

<<<FILE: backend/models.py>>>
... current content ...
<<<END FILE>>>

<<<FILE: backend/util/normalize.py>>>
... current content ...
<<<END FILE>>>

RETURN: backend/models.py, backend/util/normalize.py

DO NOT:
- touch tests
- add dependencies
- modify other files

OUTPUT FORMAT (literal markers):

<<<FILE: backend/models.py>>>
full new content
<<<END FILE>>>

(same for the other file. No prose, no fences.)
```

## Run it

```bash
cat brief.txt | maestrode --session debug --files runs/work/ --max-tokens 32000

# then test
cd runs/work && pytest tests/
```

## Why this works

Bench 6 measurement: structured FAIL/SUSPECT/FIX/RETURN feedback cut reasoning tokens **5x** (3.2k vs 15.8k) vs unstructured "tests are failing, fix them". The brain maps bug to file in seconds with its file tools. The muscle skips diagnosis and goes straight to the fix.

## Greenfield variant (no failing tests yet)

For a fresh build, the same delimited-block contract works. The brief gets a spec + file list instead of failures:

```
TASK: build a FastAPI items API.

ENDPOINTS:
- POST /items {name, price} -> 201 with {id, name, price}
- GET /items -> list
- GET /items/{id} -> 200 or 404
- DELETE /items/{id} -> 204 or 404

VALIDATION:
- name non-empty, price > 0; else 422

STORAGE:
- in-memory, auto-increment integer ids from 1

REQUIRED FILES (emit each as <<<FILE: ...>>>):
- backend/app.py
- backend/models.py
- backend/store.py
- backend/requirements.txt

DO NOT write tests. Tests live at backend/tests/test_api.py and use `from app import app`.

OUTPUT: delimited blocks only, no prose.
```

Bench 1 measurement on this exact task: DS flash one-shotted 9/9 tests in 30s with 4.4k tokens. Smart model alone needed 28.6k tokens. **6.5x cheaper** for identical output.

## Iteration

If tests still fail after maestrode's first response, the session keeps history. Send a SHORTER follow-up with only the new info:

```
1 test still fails:
FAIL: test_validation_negative_price
ASSERT: r.status_code == 422
GOT: 200
SUSPECT: backend/models.py price field
FIX: add Field(gt=0)

Return only models.py.
```

Cap 3 rounds. If still stuck, the muscle has the wrong mental model. Take it over yourself.

## Tips

- **Seed test infrastructure first**: pytest's `tests/__init__.py` if you need `from app import app` resolution. Brain's job, not muscle's.
- **Show test files in the brief OR paste their content inline**: muscle has no file tools.
- **Watch for over-engineering**: muscle sometimes adds threading locks, helper modules, validators the spec did not ask for. Trim those in review.
- **Use `--warmup` on a fresh session** before the first big call. Crystallizes the KV cache so subsequent rounds hit it.
