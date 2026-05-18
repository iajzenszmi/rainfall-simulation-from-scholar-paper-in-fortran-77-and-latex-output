#!/usr/bin/env bash
# rain_scholar_f77_latex.sh
# Randomly select a recent scholarly rainfall paper using OpenAlex,
# generate a Fortran 77 rainfall/runoff simulation demo inspired by it,
# run the demo, and publish results as LaTeX/PDF.
#
# Usage:
#   chmod +x rain_scholar_f77_latex.sh
#   ./rain_scholar_f77_latex.sh
#
# Optional environment variables:
#   RAIN_QUERY="rainfall runoff hydrology"
#   FROM_DATE="2024-01-01"
#   SAMPLE_SIZE=50
#   SEED=12345
#   OPENALEX_MAILTO="you@example.com"

set -euo pipefail

WORKDIR="${WORKDIR:-rain_paper_f77_report}"
RAIN_QUERY="${RAIN_QUERY:-rainfall precipitation runoff hydrology}"
FROM_DATE="${FROM_DATE:-2024-01-01}"
SAMPLE_SIZE="${SAMPLE_SIZE:-50}"
SEED="${SEED:-}"
OPENALEX_MAILTO="${OPENALEX_MAILTO:-}"

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    echo "On Ubuntu/Debian try: sudo apt update && sudo apt install -y $2" >&2
    exit 1
  fi
}

need_cmd python3 python3
need_cmd gfortran gfortran

mkdir -p "$WORKDIR"
cd "$WORKDIR"

cat > driver.py <<'PY'
#!/usr/bin/env python3
import csv
import datetime as dt
import json
import math
import os
import random
import re
import statistics
import subprocess
import sys
import textwrap
import urllib.parse
import urllib.request

API = "https://api.openalex.org/works"


def clean_text(s, limit=None):
    s = s or ""
    s = re.sub(r"\s+", " ", s).strip()
    if limit and len(s) > limit:
        return s[:limit-3].rstrip() + "..."
    return s


def tex_escape(s):
    s = clean_text(s)
    repl = {
        "\\": r"\textbackslash{}",
        "&": r"\&", "%": r"\%", "$": r"\$", "#": r"\#",
        "_": r"\_", "{": r"\{", "}": r"\}",
        "~": r"\textasciitilde{}", "^": r"\textasciicircum{}",
    }
    return "".join(repl.get(ch, ch) for ch in s)


def abstract_from_inverted_index(inv):
    if not inv:
        return ""
    pairs = []
    for word, positions in inv.items():
        for pos in positions:
            pairs.append((pos, word))
    pairs.sort()
    return clean_text(" ".join(word for _, word in pairs))


def fetch_candidates():
    query = os.environ.get("RAIN_QUERY", "rainfall precipitation runoff hydrology")
    from_date = os.environ.get("FROM_DATE", "2024-01-01")
    sample_size = int(os.environ.get("SAMPLE_SIZE", "50"))
    mailto = os.environ.get("OPENALEX_MAILTO", "").strip()

    params = {
        "search": query,
        "filter": f"from_publication_date:{from_date},type:article,has_abstract:true,is_retracted:false",
        "sort": "publication_date:desc",
        "per-page": str(max(5, min(sample_size, 200))),
    }
    if mailto:
        params["mailto"] = mailto

    url = API + "?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(
        url,
        headers={"User-Agent": "rainfall-f77-latex-demo/1.0"},
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        payload = json.loads(resp.read().decode("utf-8"))

    results = payload.get("results", [])
    keep = []
    key_terms = re.compile(
        r"rainfall|precipitation|rainstorm|monsoon|runoff|flood|stormwater|hydrolog",
        re.I,
    )
    for work in results:
        title = clean_text(work.get("title") or work.get("display_name") or "")
        abstract = abstract_from_inverted_index(work.get("abstract_inverted_index"))
        hay = f"{title} {abstract}"
        if title and abstract and key_terms.search(hay):
            keep.append(work)

    if not keep:
        raise SystemExit("No suitable recent rainfall papers found. Try a broader RAIN_QUERY or older FROM_DATE.")
    return keep, payload.get("meta", {}), url


def choose_paper(candidates):
    seed = os.environ.get("SEED", "").strip()
    if seed:
        random.seed(int(seed))
    else:
        random.seed()
    return random.choice(candidates)


def source_name(work):
    loc = work.get("primary_location") or {}
    src = loc.get("source") or {}
    return clean_text(src.get("display_name") or "Unknown source")


def authors_text(work, max_auth=6):
    names = []
    for au in work.get("authorships", [])[:max_auth]:
        a = au.get("author") or {}
        if a.get("display_name"):
            names.append(a["display_name"])
    if not names:
        return "Unknown authors"
    more = len(work.get("authorships", [])) > max_auth
    return ", ".join(names) + (", et al." if more else "")


def derive_params(work):
    title = clean_text(work.get("title") or work.get("display_name") or "")
    abstract = abstract_from_inverted_index(work.get("abstract_inverted_index"))
    text = f"{title} {abstract}".lower()

    params = {
        "w0": 0.28,
        "pers": 0.35,
        "rmean": 10.0,
        "hprob": 0.045,
        "hfac": 3.0,
        "rcoef": 0.22,
        "etbas": 3.0,
        "cap": 90.0,
        "infil": 0.70,
        "trend": 0.00,
    }

    adjustments = []

    def bump(key, delta, reason):
        params[key] += delta
        adjustments.append(reason)

    if re.search(r"extreme|heavy|intense|intensity|torrential", text):
        bump("rmean", 4.0, "extreme/heavy rainfall language raised storm rainfall mean")
        bump("hprob", 0.035, "extreme/heavy rainfall language raised heavy-event probability")
        bump("hfac", 1.0, "extreme/heavy rainfall language raised heavy-event multiplier")

    if re.search(r"flood|flash flood|inundation", text):
        bump("rcoef", 0.12, "flood language raised direct runoff coefficient")
        bump("cap", -15.0, "flood language lowered effective soil storage")

    if re.search(r"urban|impervious|stormwater|city|cities", text):
        bump("rcoef", 0.16, "urban/impervious language raised direct runoff coefficient")
        bump("infil", -0.12, "urban/impervious language lowered infiltration fraction")

    if re.search(r"drought|arid|semi-arid|dry spell|dry-spell", text):
        bump("w0", -0.08, "dry/drought language lowered base wet-day probability")
        bump("etbas", 0.8, "dry/drought language raised evapotranspiration demand")

    if re.search(r"monsoon|seasonal|seasonality", text):
        bump("pers", 0.10, "monsoon/seasonal language raised wet-spell persistence")

    if re.search(r"climate change|warming|future climate|projection|cmip", text):
        bump("trend", 0.12, "climate-change/projection language added a rainfall-intensity trend")

    params["w0"] = min(max(params["w0"], 0.05), 0.70)
    params["pers"] = min(max(params["pers"], 0.00), 0.80)
    params["rmean"] = min(max(params["rmean"], 2.0), 45.0)
    params["hprob"] = min(max(params["hprob"], 0.00), 0.35)
    params["hfac"] = min(max(params["hfac"], 1.0), 9.0)
    params["rcoef"] = min(max(params["rcoef"], 0.02), 0.85)
    params["etbas"] = min(max(params["etbas"], 0.5), 8.0)
    params["cap"] = min(max(params["cap"], 25.0), 220.0)
    params["infil"] = min(max(params["infil"], 0.10), 0.95)
    params["trend"] = min(max(params["trend"], -0.20), 0.45)

    if not adjustments:
        adjustments.append("no strong modelling keywords found; used conservative default rainfall-runoff parameters")

    return params, adjustments, abstract


def f77_num(x):
    return f"{x:.6f}D0"


def write_fortran(work, params):
    title = clean_text(work.get("title") or work.get("display_name") or "Untitled", 66)
    f77 = f"""      PROGRAM RAIN77
C     RAINFALL/RUNOFF DEMO GENERATED FROM A SCHOLARLY PAPER
C     SELECTED PAPER: {title}
C
C     DATA DICTIONARY
C     DAY    = DAY NUMBER, 1 TO 365
C     RAIN   = DAILY RAINFALL DEPTH, MILLIMETRES
C     RUNOF  = DAILY RUNOFF DEPTH, MILLIMETRES
C     SOIL   = SIMPLE SOIL WATER STORE, MILLIMETRES
C     ET     = POTENTIAL EVAPOTRANSPIRATION, MILLIMETRES
C     WET    = 1 FOR WET DAY, 0 FOR DRY DAY
C     W0     = BASE WET-DAY PROBABILITY
C     PERS   = EXTRA WET-DAY PROBABILITY AFTER A WET DAY
C     RMEAN  = MEAN RAINFALL INTENSITY FOR ORDINARY WET DAYS
C     HPROB  = PROBABILITY THAT A WET DAY IS HEAVY
C     HFAC   = HEAVY-EVENT RAINFALL MULTIPLIER
C     RCOEF  = DIRECT RUNOFF COEFFICIENT
C     CAP    = SOIL STORAGE CAPACITY
C     INFIL  = INFILTRATING FRACTION OF RAINFALL
C     TREND  = LINEAR INTENSITY TREND OVER ONE SYNTHETIC YEAR
C
      INTEGER NDAYS,DAY,ISEED,K,WET
      DOUBLE PRECISION U,RAIN,RUNOF,SOIL,PWET,W0,PERS,RMEAN
      DOUBLE PRECISION HPROB,HFAC,RCOEF,ETBAS,CAP,INFIL
      DOUBLE PRECISION TREND,ET,TOTR,TOTQ,MAXR,MAXQ,PI,T,SEA
      DOUBLE PRECISION MEANF,EXC
      PARAMETER (NDAYS=365)
      DATA W0/{f77_num(params['w0'])}/
      DATA PERS/{f77_num(params['pers'])}/
      DATA RMEAN/{f77_num(params['rmean'])}/
      DATA HPROB/{f77_num(params['hprob'])}/
      DATA HFAC/{f77_num(params['hfac'])}/
      DATA RCOEF/{f77_num(params['rcoef'])}/
      DATA ETBAS/{f77_num(params['etbas'])}/
      DATA CAP/{f77_num(params['cap'])}/
      DATA INFIL/{f77_num(params['infil'])}/
      DATA TREND/{f77_num(params['trend'])}/
      DATA PI/3.141592653589793D0/
      ISEED = 1357911
      SOIL = 0.50D0*CAP
      WET = 0
      TOTR = 0.0D0
      TOTQ = 0.0D0
      MAXR = 0.0D0
      MAXQ = 0.0D0
      OPEN(10,FILE='results.csv',STATUS='UNKNOWN')
      WRITE(10,*) 'day,rain_mm,runoff_mm,soil_mm,et_mm,wet'
      DO 100 DAY = 1, NDAYS
         K = ISEED / 127773
         ISEED = 16807*(ISEED-K*127773)-2836*K
         IF (ISEED .LE. 0) ISEED = ISEED + 2147483647
         U = DBLE(ISEED)*4.656612875D-10
         PWET = W0 + PERS*DBLE(WET)
         IF (PWET .GT. 0.95D0) PWET = 0.95D0
         RAIN = 0.0D0
         IF (U .LT. PWET) THEN
            WET = 1
            K = ISEED / 127773
            ISEED = 16807*(ISEED-K*127773)-2836*K
            IF (ISEED .LE. 0) ISEED = ISEED + 2147483647
            U = DBLE(ISEED)*4.656612875D-10
            IF (U .LT. 1.0D-12) U = 1.0D-12
            T = DBLE(DAY-1)/DBLE(NDAYS)
            SEA = 1.0D0 + 0.25D0*DSIN(2.0D0*PI*(T-0.20D0))
            MEANF = RMEAN*SEA*(1.0D0+TREND*T)
            RAIN = -MEANF*DLOG(U)
            K = ISEED / 127773
            ISEED = 16807*(ISEED-K*127773)-2836*K
            IF (ISEED .LE. 0) ISEED = ISEED + 2147483647
            U = DBLE(ISEED)*4.656612875D-10
            IF (U .LT. HPROB) RAIN = RAIN*HFAC
         ELSE
            WET = 0
         ENDIF
         T = DBLE(DAY-1)/DBLE(NDAYS)
         ET = ETBAS*(1.0D0+0.35D0*DSIN(2.0D0*PI*(T-0.05D0)))
         RUNOF = RCOEF*RAIN
         SOIL = SOIL + INFIL*RAIN - ET
         IF (SOIL .GT. CAP) THEN
            EXC = SOIL - CAP
            RUNOF = RUNOF + EXC
            SOIL = CAP
         ENDIF
         IF (SOIL .LT. 0.0D0) SOIL = 0.0D0
         TOTR = TOTR + RAIN
         TOTQ = TOTQ + RUNOF
         IF (RAIN .GT. MAXR) MAXR = RAIN
         IF (RUNOF .GT. MAXQ) MAXQ = RUNOF
         WRITE(10,900) DAY,RAIN,RUNOF,SOIL,ET,WET
  100 CONTINUE
      CLOSE(10)
      OPEN(11,FILE='summary.txt',STATUS='UNKNOWN')
      WRITE(11,*) 'Synthetic rainfall/runoff demo summary'
      WRITE(11,*) 'Total rainfall mm: ', TOTR
      WRITE(11,*) 'Total runoff mm:   ', TOTQ
      WRITE(11,*) 'Maximum rain mm:   ', MAXR
      WRITE(11,*) 'Maximum runoff mm: ', MAXQ
      CLOSE(11)
      WRITE(*,*) 'Wrote results.csv and summary.txt'
  900 FORMAT(I4,',',F10.3,',',F10.3,',',F10.3,',',F10.3,',',I1)
      END
"""
    with open("rainfall_demo.f", "w", encoding="ascii", errors="ignore") as f:
        f.write(f77)


def write_metadata(work, params, adjustments, abstract, meta, url):
    loc = work.get("primary_location") or {}
    data = {
        "selected_at_utc": dt.datetime.utcnow().isoformat(timespec="seconds") + "Z",
        "openalex_query_url": url,
        "openalex_meta": meta,
        "paper": {
            "title": clean_text(work.get("title") or work.get("display_name") or ""),
            "authors": authors_text(work),
            "publication_year": work.get("publication_year"),
            "publication_date": work.get("publication_date"),
            "doi": work.get("doi"),
            "openalex_id": work.get("id"),
            "source": source_name(work),
            "landing_page_url": loc.get("landing_page_url"),
            "cited_by_count": work.get("cited_by_count"),
            "abstract": abstract,
        },
        "model_parameters": params,
        "parameter_adjustments": adjustments,
    }
    with open("paper_metadata.json", "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)


def fetch_and_generate():
    candidates, meta, url = fetch_candidates()
    work = choose_paper(candidates)
    params, adjustments, abstract = derive_params(work)
    write_fortran(work, params)
    write_metadata(work, params, adjustments, abstract, meta, url)
    print("Selected paper:", clean_text(work.get("title") or work.get("display_name") or ""))
    print("Publication date:", work.get("publication_date"))
    print("Source:", source_name(work))
    print("Generated rainfall_demo.f")


def read_results():
    rows = []
    with open("results.csv", newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f, skipinitialspace=True)
        for row in reader:
            rows.append({
                "day": int(row["day"]),
                "rain": float(row["rain_mm"]),
                "runoff": float(row["runoff_mm"]),
                "soil": float(row["soil_mm"]),
                "et": float(row["et_mm"]),
                "wet": int(row["wet"]),
            })
    return rows


def summarize(rows):
    rains = [r["rain"] for r in rows]
    q = [r["runoff"] for r in rows]
    wet_days = sum(1 for r in rows if r["wet"] == 1)
    return {
        "days": len(rows),
        "wet_days": wet_days,
        "total_rain": sum(rains),
        "total_runoff": sum(q),
        "max_rain": max(rains),
        "max_runoff": max(q),
        "mean_rain": statistics.mean(rains),
        "mean_runoff": statistics.mean(q),
        "runoff_ratio": sum(q) / sum(rains) if sum(rains) > 0 else 0.0,
    }


def write_latex():
    with open("paper_metadata.json", encoding="utf-8") as f:
        meta = json.load(f)
    rows = read_results()
    summ = summarize(rows)
    paper = meta["paper"]
    params = meta["model_parameters"]
    adjustments = meta["parameter_adjustments"]

    sample_rows = rows[:10]
    table_lines = []
    for r in sample_rows:
        table_lines.append(
            f"{r['day']} & {r['rain']:.2f} & {r['runoff']:.2f} & "
            f"{r['soil']:.2f} & {r['et']:.2f} & {r['wet']} \\\\" 
        )

    param_lines = []
    for k, v in params.items():
        param_lines.append(f"{tex_escape(k)} & {v:.4f} \\\\")

    adj_lines = "\n".join(f"\\item {tex_escape(a)}" for a in adjustments)
    abstract = tex_escape(clean_text(paper.get("abstract", ""), 1500))

    tex = rf"""
\documentclass[11pt]{{article}}
\usepackage[a4paper,margin=2.2cm]{{geometry}}
\usepackage{{booktabs}}
\usepackage{{hyperref}}
\usepackage{{longtable}}
\usepackage{{listings}}
\title{{Fortran 77 Rainfall Simulation Demo from a Random Recent Paper}}
\author{{Automated OpenAlex + Fortran 77 + LaTeX Pipeline}}
\date{{{tex_escape(dt.date.today().isoformat())}}}
\begin{{document}}
\maketitle

\section*{{Selected scholarly paper}}
\begin{{description}}
\item[Title] {tex_escape(paper.get('title'))}
\item[Authors] {tex_escape(paper.get('authors'))}
\item[Source] {tex_escape(paper.get('source'))}
\item[Publication date] {tex_escape(str(paper.get('publication_date')))}
\item[DOI] {tex_escape(str(paper.get('doi') or 'not listed'))}
\item[OpenAlex ID] \url{{{paper.get('openalex_id') or ''}}}
\item[Landing page] \url{{{paper.get('landing_page_url') or ''}}}
\item[Cited by count] {tex_escape(str(paper.get('cited_by_count')))}
\end{{description}}

\section*{{Abstract used by the script}}
{abstract}

\section*{{Modelling note}}
This report is an \emph{{abstract-driven demonstration}}, not a reproduction of the
paper's full methods. The script uses the selected title and abstract to tune a
small stochastic rainfall--runoff bucket model. It is suitable for software,
Fortran 77, and reproducibility demonstrations, not for operational forecasting.

\section*{{Parameter choices inferred from paper language}}
\begin{{itemize}}
{adj_lines}
\end{{itemize}}

\begin{{center}}
\begin{{tabular}}{{lr}}
\toprule
Parameter & Value \\
\midrule
{chr(10).join(param_lines)}
\bottomrule
\end{{tabular}}
\end{{center}}

\section*{{Simulation summary}}
\begin{{center}}
\begin{{tabular}}{{lr}}
\toprule
Metric & Value \\
\midrule
Days simulated & {summ['days']} \\
Wet days & {summ['wet_days']} \\
Total rainfall, mm & {summ['total_rain']:.2f} \\
Total runoff, mm & {summ['total_runoff']:.2f} \\
Runoff/rainfall ratio & {summ['runoff_ratio']:.3f} \\
Maximum daily rainfall, mm & {summ['max_rain']:.2f} \\
Maximum daily runoff, mm & {summ['max_runoff']:.2f} \\
Mean daily rainfall, mm & {summ['mean_rain']:.2f} \\
Mean daily runoff, mm & {summ['mean_runoff']:.2f} \\
\bottomrule
\end{{tabular}}
\end{{center}}

\section*{{First 10 simulated days}}
\begin{{center}}
\begin{{tabular}}{{rrrrrr}}
\toprule
Day & Rain & Runoff & Soil & ET & Wet \\
\midrule
{chr(10).join(table_lines)}
\bottomrule
\end{{tabular}}
\end{{center}}

\section*{{Generated Fortran 77 source}}
The generated source file is \texttt{{rainfall\_demo.f}}. The daily output is
\texttt{{results.csv}}, and the plain-text summary is \texttt{{summary.txt}}.

\lstinputlisting[language=Fortran,basicstyle=\ttfamily\scriptsize,
breaklines=true]{{rainfall_demo.f}}

\end{{document}}
"""
    with open("report.tex", "w", encoding="utf-8") as f:
        f.write(tex.strip() + "\n")
    print("Generated report.tex")


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in {"fetch_and_generate", "report"}:
        raise SystemExit("Usage: driver.py fetch_and_generate|report")
    if sys.argv[1] == "fetch_and_generate":
        fetch_and_generate()
    else:
        write_latex()


if __name__ == "__main__":
    main()
PY

python3 driver.py fetch_and_generate

echo "Compiling generated Fortran 77 demo..."
gfortran -std=legacy -Wall -Wextra rainfall_demo.f -o rainfall_demo

echo "Running simulation..."
./rainfall_demo

python3 driver.py report

if command -v pdflatex >/dev/null 2>&1; then
  echo "Building PDF with pdflatex..."
  pdflatex -interaction=nonstopmode -halt-on-error report.tex >/dev/null
  pdflatex -interaction=nonstopmode -halt-on-error report.tex >/dev/null
  echo "Done: $WORKDIR/report.pdf"
else
  echo "pdflatex not found; report.tex was generated but PDF was not built." >&2
  echo "On Ubuntu/Debian try: sudo apt install -y texlive-latex-base texlive-latex-extra" >&2
fi

echo
printf '%s\n' "Created files in $WORKDIR:" \
  "  paper_metadata.json" \
  "  rainfall_demo.f" \
  "  rainfall_demo" \
  "  results.csv" \
  "  summary.txt" \
  "  report.tex" \
  "  report.pdf, if pdflatex was available"
