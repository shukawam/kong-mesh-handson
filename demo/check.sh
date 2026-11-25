#!/usr/bin/env bash
# productpage を N 回呼び出し、応答した reviews のバージョン・所要時間・ratings の取得結果を 1 行ずつ表示する
set -euo pipefail

CONTEXT=${KUBE_CONTEXT:-kind-kong-mesh}
NAMESPACE=${DEMO_NAMESPACE:-bookinfo}
COUNT=${COUNT:-10}
PORT=${PORT:-19080}

kubectl --context "$CONTEXT" -n "$NAMESPACE" port-forward svc/productpage "$PORT:9080" >/dev/null 2>&1 &
pf=$!
trap 'kill $pf 2>/dev/null' EXIT
until curl -s -o /dev/null "http://localhost:$PORT/"; do sleep 0.2; done

for i in $(seq 1 "$COUNT"); do
  res=$(curl -s -w '\n%{time_total}' "http://localhost:$PORT/productpage")
  time=$(tail -n 1 <<<"$res")
  version=$(grep -A1 'Reviews served by' <<<"$res" | tail -n 1 | grep -oE 'reviews-v[0-9]+' || echo "-")
  if [[ $version == "-" ]]; then
    ratings="reviews unavailable"
  elif [[ $version == reviews-v1 ]]; then
    ratings="-"
  elif grep -q 'Ratings service is currently unavailable' <<<"$res"; then
    ratings="unavailable"
  else
    ratings="ok"
  fi
  printf '%2d  %-10s  %5.2fs  ratings: %s\n' "$i" "$version" "$time" "$ratings"
done
