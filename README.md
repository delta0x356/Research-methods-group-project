# SEC Tick Size Pilot: Effect on Trading Volume

## Research Question
Does the minimum tick size increase from $0.01 to $0.05 reduce equity trading volume, and is the effect concentrated in stocks whose pre-treatment quoted spread was below $0.05?

## Methodology
Difference-in-differences exploiting the SEC Tick Size Pilot Program (October 2016), in which approximately 1,200 small-cap stocks were randomly assigned to treatment or control via stratified sampling.

**Baseline specification:**

`Volume_it = α + β1(G1_i × Post_t) + β2(G2_i × Post_t) + β3(G3_i × Post_t) + γ_i + δ_t + ε_it`

**Extended specification (heterogeneous effects):**

`Volume_it = α + Σk βk(Gk_i × Post_t) + Σk γk(Gk_i × Post_t × SmallSpread_i) + γ_i + δ_t + ε_it`

## Treatment Groups
| Group | Assignment | N (approx.) |
|-------|-----------|-------------|
| G1 | Quote in $0.05 increments, trade at any increment | 400 |
| G2 | Quote and trade in $0.05 increments | 400 |
| G3 | G2 requirements + trade-at prohibition | 400 |
| C | Control, continue at $0.01 | 1,400 |

## Key Variables
- **Volume_it**: log daily share volume / dollar volume / turnover (CRSP)
- **Post_t**: = 1 on or after October 3, 2016 (October 31 for G3)
- **SmallSpread_i**: = 1 if average pre-treatment dollar quoted spread < $0.05 (TAQ, 6-month pre-period)
- **Controls**: log market cap, inverse price, realized volatility (all lagged one day)
- **Fixed effects**: firm and date

## Sample
- **Period**: January 1, 2016 to April 30, 2019
- **Universe**: Small-cap common stocks from CRSP (PERMNO identifier)
- **Exclusions**: Delisted stocks at point of delisting; observations with missing volume data
- **Treatment list**: `Treatmentcontrollist.csv` (PERMNO, group assignment)

## Data Sources
- **CRSP**: Daily stock prices, volume, returns, market cap
- **TAQ**: Daily quoted spreads for SmallSpread construction
- **WRDS**: Access via class code `628d431c`

## References
- Albuquerque, Song, and Yao (2020). *Journal of Financial Economics*, 138(3), 700-724.
- Amihud and Mendelson (1986). *Journal of Financial Economics*, 17(2), 223-249.
- Bessembinder (2003). *Journal of Financial and Quantitative Analysis*, 38(4), 747-777.
- Chordia, Roll, and Subrahmanyam (2001). *Journal of Finance*, 56(2), 501-530.
- Foley and Putniņš (2016). *Journal of Financial Economics*, 122(3), 456-481.
- Harris (1994). *Review of Financial Studies*, 7(1), 149-178.
