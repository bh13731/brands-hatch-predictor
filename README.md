# Brands Hatch GP — Caterham Academy Top-10 Predictor
Static site (GitHub Pages) + tiny Python API behind a cloudflared tunnel.
Every competitor picks their top 10; closest to the real finishing order wins.
Scoring: sum of |predicted − actual| positions, lowest wins; exact hits break ties.
