"""
Convert CubeCobra's public JSON export to Parquet.

Three JSON shapes show up in this dataset:
  - array-of-objects   (cubes.json)                -> straight to DataFrame
  - object keyed by id (carddict, metadatadict,
    indexToOracleMap, oracleToId, oracleTagDict...) -> needs reshaping,
    since a plain DataFrame() call on a dict treats keys as columns.
  - array-of-scalars   (oracleTagNames)            -> keyed by position
"""

import json
import os

import pandas as pd

RAW = "raw"
OUT = "processed"
os.makedirs(OUT, exist_ok=True)


def _oid_to_hex(obj):
    """json `object_hook`: turn a leaked Mongo ObjectID back into its hex string.

    A few legacy ids are exported as
      {"_bsontype": "ObjectID", "id": {"type": "Buffer", "data": [<12 bytes>]}, ...}
    instead of the usual 24-char hex string (e.g. one entry of one cube's
    `following`). Left alone, that dict inside a list of strings makes
    pyarrow fail with "Expected bytes, got a 'dict' object".
    """
    if obj.get("_bsontype") == "ObjectID":
        return bytes(obj["id"]["data"]).hex()
    return obj


def load_json(name):
    with open(os.path.join(RAW, name)) as f:
        return json.load(f, object_hook=_oid_to_hex)


def map_to_df(data, key_name="key"):
    """Turn a {key: value} JSON object (or array of scalars) into a tidy DataFrame.

    Handles three shapes of `value`:
      - dict  (e.g. carddict: {oracle_id: {name: ..., cmc: ...}})
      - list  (e.g. oracleTagDict: {oracle_id: [tag1, tag2]})
      - scalar (e.g. indexToOracleMap: {"0": "uuid-string"})
    """
    if not data:
        return pd.DataFrame({key_name: []})

    if isinstance(data, list):  # e.g. oracleTagNames: ["tag-a", "tag-b"] -> {0: "tag-a", 1: "tag-b"}
        data = dict(enumerate(data))

    sample = next(iter(data.values()))

    if isinstance(sample, dict):
        df = pd.DataFrame.from_dict(data, orient="index")
        df.index.name = key_name
        return df.reset_index()

    if isinstance(sample, list):
        return pd.DataFrame({key_name: list(data.keys()), "value": list(data.values())})

    # scalar values (strings, numbers)
    return pd.DataFrame({key_name: list(data.keys()), "value": list(data.values())})


def convert(name, out_name, key_name="key", is_array=False):
    data = load_json(name)

    if is_array:
        df = pd.DataFrame(data)
        n_source = len(data)
    else:
        df = map_to_df(data, key_name=key_name)
        n_source = len(data)

    out_path = os.path.join(OUT, out_name)
    df.to_parquet(out_path, index=False)

    n_rows = len(df)
    status = "OK" if n_rows == n_source else "MISMATCH"
    print(f"{name:30s} -> {out_name:25s} source_keys={n_source:>7d} "
          f"parquet_rows={n_rows:>7d} [{status}]")


if __name__ == "__main__":
    convert("cubes.json", "cubes.parquet", is_array=True)
    convert("export_indexToOracle.json", "export_index_to_oracle.parquet", key_name="index")
    convert("carddict.json", "carddict.parquet", key_name="id")
    convert("metadatadict.json", "metadatadict.parquet", key_name="id")
    convert("oracleToId.json", "oracle_to_id.parquet", key_name="oracle_id")
    convert("oracleTagDict.json", "oracle_tag_dict.parquet", key_name="oracle_id")
    convert("oracleTagNames.json", "oracle_tag_names.parquet", key_name="tag_id")
