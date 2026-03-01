# Code Review: Group18_do_file.do
**Reviewed against:** Task Assignment, TA Session Notes, Albuquerque et al. (2020)

---

## 1. Changes from v2.5.do → Group18_do_file.do

### A. Infrastructure & Paths
| Aspect | v2.5.do | Group18_do_file.do |
|---|---|---|
| Input data folder | `data/` | `data_and_results/` |
| Output folder | `results/` | `data_and_results/` (same as input) |
| Treatment data | `tempfile` (in-memory) | Saved permanently as `treatment_data.dta` |
| CSV delimiter | `,` (comma) | `;` (semicolon) |
| Package installed | + `coefplot` | No `coefplot` |

> **Note:** The semicolon delimiter change is likely a correct practical fix for the actual CSV file format. Merging input/output into one folder is a simplification but functionally fine.

---

### B. Penny Stock Filter (Step 3 — most significant methodological change)

**v2.5.do (two-step, stricter):**
```stata
* Drop ENTIRE FIRM if it ever trades below $1
bysort permno: egen ever_below_1 = max(abs(prc) < 1)
drop if ever_below_1 == 1

* Also drop individual daily observations where price < $2
drop if abs(prc) < 2
```

**Group18 (one-step, more lenient):**
```stata
* Drop only individual daily observations where price < $1
drop if abs(prc) < 1
```

**Assessment:** Group18 is **more lenient** and deviates from Albuquerque et al. (2020), who drop entire firms that ever fall below $1. v2.5 was closer to the paper. The Group18 approach risks keeping penny-stock firms in the sample as long as *most* of their observations are above $1, which could contaminate the panel.

---

### C. Additional Control Variable: `abs_ret` / `L_abs_ret`

**v2.5.do:** No absolute return variable — regressions use only `Inv_Price` as control.

**Group18:** Adds absolute return:
```stata
gen abs_ret = abs(ret)
winsor2 ... abs_ret, cuts(1 99) replace   * winsorized
xtset permno date_id
gen L_abs_ret = L.abs_ret                 * lagged 1 day
```
Both regressions (H1 and H2) then include `Inv_Price L_abs_ret` as controls.

**Assessment:** This is an **improvement** that brings the code closer to the paper. Albuquerque et al. (2020) include lagged absolute return (a proxy for volatility) as a control variable. The use of `xtset` with a sequential `date_id` (rather than actual calendar date) is also correct and avoids spurious lags over weekends.

---

### D. Output Format

| | v2.5.do | Group18_do_file.do |
|---|---|---|
| Table 1 | Excel (`.xlsx`) via `putexcel` with full formatting | CSV via `esttab` |
| Regression results | Excel (`.xlsx`) via `putexcel` with full formatting | CSV via `esttab` |
| Figures | **8 figures** (PNG, 1400×900) | **None** |

**Assessment:** Group18 removes all 8 figures and simplifies output to CSV. Figures are not required by the task assignment, so this is acceptable for the submitted script. However, parallel trends plots (Figure 2 in v2.5) are valuable evidence supporting the DiD identifying assumption and would strengthen the written paper.

---

### E. Other Differences

| | v2.5.do | Group18_do_file.do |
|---|---|---|
| Variable labels | Added before Table 1 | Not added |
| `group_id` variable | Created for graphing | Not created |
| Step count | Steps 0–11 | Steps 0–10 |
| H2 step label | Step 8 | Step 9 |

---

## 2. Alignment with the Task Assignment

| Requirement | Group18 Status |
|---|---|
| Data: Jan 1, 2016 – Apr 30, 2019 | ✅ Correct (`td(01jan2016)` to `td(30apr2019)`) |
| Treatment groups G1/G2/G3 + Control | ✅ Correct |
| Summary stats conditioned on treatment group only (not spread) | ✅ Correct — Table 1 splits by group, not SmallSpread |
| Only include variables you will use in summary stats | ⚠️ Minor issue — `ln_volume` and `turnover` appear in Table 1 but are not directly used as regression variables |
| Submit script to obtain results | ✅ Script is clean and runnable |
| Two hypotheses linking tick size and volume | ✅ H1 (average effect) and H2 (heterogeneous effect via SmallSpread) |
| DiD methodology | ✅ `reghdfe` with firm + date FE, clustered SE at firm level |
| Controls justified | ✅ `Inv_Price` (standard) + `L_abs_ret` (volatility proxy) |

### One task note to re-read:
> *"Do not condition on small and quoted spread when computing the summary statistics but condition on treatment as they do (control, group 1, etc.)"*

The code correctly computes Table 1 statistics separately for Control, G1, G2, G3 without any spread conditioning. ✅

---

## 3. Alignment with Albuquerque et al. (2020)

| Paper Approach | Group18 Status |
|---|---|
| Treatment start: Oct 17, 2016 (G1/G2), Oct 31, 2016 (G3) | ✅ Correct |
| Treatment end: Sep 28, 2018 | ✅ Correct |
| Drop M&A firms (dlstcd 200–299) entirely | ✅ Correct |
| Drop delisted firms (dlstcd 400–599) | ✅ Correct (drops entire firm) |
| Keep only share codes 10 or 11 | ✅ Correct |
| Drop firms that ever fall below $1 | ❌ Group18 only drops *daily observations* below $1, not entire firms |
| Quoted spread as liquidity variable | ✅ Computed as `ask - bid` |
| SmallSpread threshold: pre-treatment average spread < $0.05 | ✅ Correct |
| 6-month pre-treatment window for spread classification | ✅ Apr–Oct 2016 (G1/G2/C), May–Oct 2016 (G3) |
| Inverse price as control | ✅ Correct |
| Lagged absolute return as control | ✅ Added in Group18 (improvement over v2.5) |
| Winsorize at 1%/99% | ✅ Correct (paper uses 0.5%/99.5% for some — minor difference) |
| Log turnover as dependent variable | ✅ Correct |
| Firm FE + Date FE | ✅ `absorb(permno date)` |
| Clustered SE at firm level | ✅ `vce(cluster permno)` |
| Post-pilot reversal period | ✅ `postpilot = (date > td(28sep2018))` included in both models |

---

## 4. Summary Assessment

**The Group18 file is largely well-aligned with the task and paper.** The core econometric structure — DiD with firm/date fixed effects, clustered SEs, the two-hypothesis framework, and the SmallSpread heterogeneity split — is correct and consistent with Albuquerque et al. (2020).

**Two issues worth addressing before submission:**

1. **Penny stock filter (most important):** The current daily-observation drop at `abs(prc) < 1` is weaker than what the paper does. Consider adding back the firm-level drop for firms that *ever* fall below $1, as in v2.5. This avoids including distressed/penny-stock firms during their "healthy" periods.

2. **Summary statistics variables:** `ln_volume` and `turnover` appear in Table 1 but are not regression variables. Either (a) use them somewhere in the regressions, or (b) remove them from Table 1 to comply with the task instruction to "include only the variables you will use."

**What improved from v2.5 → Group18:**
- The addition of `L_abs_ret` as a regression control is a genuine improvement over v2.5 and closer to the paper.
- The semicolon delimiter fix is practically necessary.

---
*Report generated March 1, 2026*
