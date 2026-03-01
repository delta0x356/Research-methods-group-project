clear all
set more off

*******************************************************
* SET WORKING DIRECTORY (ROBUST AUTOMATION)
*******************************************************
* Sets the working directory to the folder containing this .do file.
if "`c(do_file)'" != "" {
    local _dir = ustrregexra("`c(do_file)'", "[/\\][^/\\]*$", "")
    if "`_dir'" != "" & "`_dir'" != "`c(do_file)'" cd "`_dir'"
}

* All output files (tables, figures) go to the project-level results folder
local outdir "../results"
cap mkdir "`outdir'"

* Verify files exist in the /data_and_results/ subfolder before starting
capture confirm file "data_and_results/Treatmentcontrollist.csv"
if _rc {
    di as error "Error: Treatmentcontrollist.csv not found in `c(pwd)'/data_and_results"
    exit 601
}

capture confirm file "data_and_results/dataset.dta"
if _rc {
    di as error "Error: dataset.dta not found in `c(pwd)'/data_and_results"
    exit 601
}

*******************************************************
* STEP 0: INSTALL REQUIRED PACKAGES
*******************************************************
cap ssc install ftools,   replace
cap ssc install reghdfe,  replace
cap ssc install require,  replace
cap ssc install estout,   replace
cap ssc install winsor2,  replace
mata: mata mlib index

*******************************************************
* STEP 1: PREPARE THE TREATMENT FILE
*******************************************************
* Import from the /data_and_results/ subfolder
import delimited "data_and_results/Treatmentcontrollist.csv", delimiter(";") clear
rename *, lower

* Create mutually exclusive pilot group indicators and control indicator
gen g1      = (group == "G1")
gen g2      = (group == "G2")
gen g3      = (group == "G3")
gen control = (group == "C")

* Save cleaned treatment file
save "data_and_results/treatment_data.dta", replace

*******************************************************
* STEP 2: LOAD WRDS DATA AND MERGE
*******************************************************
* Load daily CRSP/WRDS panel dataset
use "data_and_results/dataset.dta", clear
rename *, lower

* Merge with the treatment assignment file created in Step 1
merge m:1 permno using "data_and_results/treatment_data.dta"

* Keep only matched observations belonging to the SEC experiment
keep if _merge == 3
drop _merge

di as text "--- Steps 1–2 complete: data loaded and merged. ---"

*******************************************************
* STEP 3: DATA CLEANING & SAMPLE CONSTRUCTION
*******************************************************
* 1. Missing data: Drop observations with missing crucial trading variables
drop if missing(vol) | missing(prc) | missing(ask) | missing(bid) | missing(shrout)

* 2. Zero / negative volume: required for log-volume transformation
drop if vol <= 0

* 3. Invalid shares outstanding or crossed quotes
drop if shrout <= 0
drop if ask <= bid

* 4. Mergers & Acquisitions: Drop the ENTIRE FIRM if it ever records M&A (codes 200–299)
bysort permno: egen has_merger = max(inrange(dlstcd, 200, 299))
drop if has_merger == 1
drop has_merger

* 5. Delistings: Drop the ENTIRE FIRM if it records a delisting/drop code (400–599)
bysort permno: egen has_dropped = max(inrange(dlstcd, 400, 599))
drop if has_dropped == 1
drop has_dropped

* 6. Ordinary Common Shares: Keep only share codes 10 or 11
keep if inrange(shrcd, 10, 11)

* NOTE: No penny-stock price filter is applied. The $1/$2 threshold
* filters used in earlier versions are removed here because:
*   (a) the ITT framework requires keeping all randomly assigned firms
*       regardless of ex-post price behaviour;
*   (b) extreme price observations are handled by winsorisation at
*       the 1st/99th percentiles in Step 4.

* 7. Restrict sample to the defined study window (Jan 1, 2016 – Apr 30, 2019)
keep if date >= td(01jan2016) & date <= td(30apr2019)

*******************************************************
* STEP 4: CONSTRUCT FINANCIAL & CONTROL VARIABLES
*******************************************************
* Daily quoted spread
gen spread = ask - bid
drop if spread <= 0

* Turnover (used for winsorisation base; log version enters regression)
gen turnover = vol / shrout

* Inverse of the daily midpoint price (time-varying control)
gen Inv_Price = 1 / ((ask + bid) / 2)

* Absolute daily return (lagged version enters regression as volatility proxy)
gen abs_ret = abs(ret)

* Winsorise continuous variables at the 1st and 99th percentiles
winsor2 turnover vol spread Inv_Price abs_ret, cuts(1 99) replace

* Construct log variables AFTER winsorising
gen ln_turnover = ln(turnover)
gen ln_volume   = ln(vol)

*******************************************************
* STEP 5: DEFINE TIMING & BINDING CONSTRAINT (SPREAD)
*******************************************************
* 1. Treatment period
*    G1 and G2: pilot active Oct 17, 2016 – Sep 28, 2018
*    G3:        pilot active Oct 31, 2016 – Sep 28, 2018 (two-week delayed start)
gen treatmentperiod = (date >= td(17oct2016) & date <= td(28sep2018))
replace treatmentperiod = (date >= td(31oct2016) & date <= td(28sep2018)) if g3 == 1

* 2. Post-pilot period (experiment over; all groups revert to $0.01 tick)
gen postpilot = (date > td(28sep2018))

* 3. Six-month pre-treatment window for firm-level spread classification
gen pre_window = (date >= td(17apr2016) & date <= td(16oct2016)) if g3 == 0
replace pre_window = (date >= td(01may2016) & date <= td(30oct2016)) if g3 == 1

* Firm-level average quoted spread over the pre-treatment window
bysort permno: egen avg_pre       = mean(spread) if pre_window == 1
bysort permno: egen firm_pre_spread = max(avg_pre)
drop avg_pre pre_window

* Drop firms with no pre-period spread data
drop if missing(firm_pre_spread)

* Binding constraint indicator: pre-treatment average spread below the $0.05 tick
gen SmallSpread = (firm_pre_spread < 0.05)

*******************************************************
* STEP 6: TABLE 1 — SUMMARY STATISTICS (PRE-TREATMENT)
*******************************************************
* Computed separately by treatment group (Control / G1 / G2 / G3).
* Only variables entering the regression models are included.
*
* Variables and their role:
*   ln_turnover     : main dependent variable
*   ln_volume       : dependent variable in robustness regressions
*   Inv_Price       : regression control (inverse price)
*   abs_ret         : regression control (one-day lag enters as L_abs_ret)
*   spread          : used to construct SmallSpread; also descriptive
*   firm_pre_spread : used to construct SmallSpread
*   SmallSpread     : heterogeneity indicator in H2 regressions
*
* Raw turnover (unlogged) is excluded; only ln_turnover enters regressions.

preserve
keep if date >= td(01mar2016) & date <= td(31aug2016)

estpost summarize ln_turnover ln_volume Inv_Price abs_ret spread firm_pre_spread SmallSpread ///
    if control == 1
est store control

estpost summarize ln_turnover ln_volume Inv_Price abs_ret spread firm_pre_spread SmallSpread ///
    if g1 == 1
est store g1

estpost summarize ln_turnover ln_volume Inv_Price abs_ret spread firm_pre_spread SmallSpread ///
    if g2 == 1
est store g2

estpost summarize ln_turnover ln_volume Inv_Price abs_ret spread firm_pre_spread SmallSpread ///
    if g3 == 1
est store g3

esttab control g1 g2 g3 ///
    using "`outdir'/Table1_SummaryStatistics.csv", ///
    cells("count mean sd min max") label replace
restore

*******************************************************
* STEP 7: PREPARE PANEL AND LAGGED RETURN VARIABLE
*******************************************************
* Create a sequential trading-day index so that L. refers to the
* previous trading day (not the previous calendar day), avoiding
* spurious missing lags over weekends and holidays.
egen date_id = group(date)
xtset permno date_id

* Lagged absolute return (abs_ret already winsorised in Step 4)
gen L_abs_ret = L.abs_ret

*======================================================
* STEP 8: ASSUMPTION CHECKS FOR DIFFERENCE-IN-DIFFERENCES
*======================================================
* The DiD estimator requires three key assumptions:
*   (1) Parallel trends in the pre-treatment period
*   (2) No anticipation effects prior to treatment
*   (3) No severe multicollinearity among regressors (especially H2)
*
* Serial correlation and heteroskedasticity are handled by
* cluster-robust standard errors (vce(cluster permno)), which allow
* arbitrary within-firm correlation over time. The Durbin-Watson
* test is not appropriate for panel data with fixed effects and
* is therefore NOT used here.

* -------------------------------------------------------
* 8A: PARALLEL TRENDS — Formal Pre-Trend F-Test
* -------------------------------------------------------
* Strategy: restrict to the pre-treatment period, interact group
* indicators with quarter dummies, and test whether those
* interactions are jointly zero. Rejection would indicate that
* treated and control groups were already diverging BEFORE the
* pilot started, invalidating the DiD assumption.
*
* Specification:
*   ln_turnover_it = alpha_i + gamma_q + beta*(Group_i x Quarter_q) + e_it
*   where alpha_i = firm FE, gamma_q = quarter FE (common time trend)
*   H0: beta = 0 for all pre-treatment quarters (no differential trends)

preserve
keep if date < td(17oct2016)

gen quarter = qofd(date)
format quarter %tq

di as text ""
di as text "========================================================"
di as text " STEP 8A: PARALLEL TRENDS PRE-TEST"
di as text " Sample: pre-treatment period only (before Oct 17, 2016)"
di as text " Firm FE + Quarter FE absorbed; testing Group x Quarter"
di as text "========================================================"

reghdfe ln_turnover ///
    c.g1#i.quarter c.g2#i.quarter c.g3#i.quarter, ///
    absorb(permno quarter) vce(cluster permno)

di as text ""
di as text "--- Joint F-tests for differential pre-trends (H0: parallel trends holds) ---"
di as text "A p-value > 0.10 supports the parallel trends assumption."
di as text ""

di as text "G1 vs. Control:"
testparm c.g1#i.quarter
local F_g1 = string(r(F), "%9.4f")
local p_g1 = string(r(p), "%9.4f")
local df_g1 = r(df)

di as text "G2 vs. Control:"
testparm c.g2#i.quarter
local F_g2 = string(r(F), "%9.4f")
local p_g2 = string(r(p), "%9.4f")
local df_g2 = r(df)

di as text "G3 vs. Control:"
testparm c.g3#i.quarter
local F_g3 = string(r(F), "%9.4f")
local p_g3 = string(r(p), "%9.4f")
local df_g3 = r(df)

* Export parallel-trends test results to CSV
file open ac using "`outdir'/Assumption_Checks.csv", write replace
file write ac "Step,Test,Group_Comparison,F_statistic,p_value,df,Note" _n
file write ac `"8A,Parallel Trends Pre-trend F-test,G1 vs Control,`F_g1',`p_g1',`df_g1',"p>0.10 supports parallel trends""' _n
file write ac `"8A,Parallel Trends Pre-trend F-test,G2 vs Control,`F_g2',`p_g2',`df_g2',"p>0.10 supports parallel trends""' _n
file write ac `"8A,Parallel Trends Pre-trend F-test,G3 vs Control,`F_g3',`p_g3',`df_g3',"p>0.10 supports parallel trends""' _n
file close ac

restore

* -------------------------------------------------------
* 8B: PARALLEL TRENDS — Visual Plot (Monthly Means by Group)
* -------------------------------------------------------
* A complementary graphical check. If lines move in parallel before
* the first vertical marker (Oct 2016), the visual supports the
* assumption even if the formal test has low power.

preserve
gen ym = mofd(date)
format ym %tm

collapse (mean) mean_ln_turnover = ln_turnover, by(ym g1 g2 g3 control)

gen group_id = .
replace group_id = 0 if control == 1
replace group_id = 1 if g1 == 1
replace group_id = 2 if g2 == 1
replace group_id = 3 if g3 == 1
drop if missing(group_id)
drop g1 g2 g3 control

reshape wide mean_ln_turnover, i(ym) j(group_id)
tsset ym

set scheme s1color
twoway ///
    (line mean_ln_turnover0 ym, lcolor(black)   lwidth(medthick)) ///
    (line mean_ln_turnover1 ym, lcolor(blue)    lwidth(medthick) lpattern(dash)) ///
    (line mean_ln_turnover2 ym, lcolor(red)     lwidth(medthick) lpattern(dot)) ///
    (line mean_ln_turnover3 ym, lcolor(dkgreen) lwidth(medthick) lpattern(longdash)), ///
    xline(`=ym(2016,10)', lcolor(gs10) lwidth(thin) lpattern(shortdash)) ///
    xline(`=ym(2018,9)',  lcolor(gs10) lwidth(thin) lpattern(shortdash)) ///
    legend(label(1 "Control") label(2 "G1 ($0.05)") ///
           label(3 "G2 ($0.10)") label(4 "G3 ($0.20)") ///
           cols(4) position(6) size(small)) ///
    title("Parallel Trends: Monthly Average Log Turnover by Group", size(medlarge)) ///
    note("Dashed vertical lines: pilot start (Oct 2016) and end (Sep 2018)", size(small)) ///
    xtitle("Month") ytitle("Mean Log Turnover") ///
    xlabel(, angle(45) labsize(small))

graph export "`outdir'/Fig_ParallelTrends_Visual.png", replace width(1400) height(900)
restore

* -------------------------------------------------------
* 8C: MULTICOLLINEARITY CHECK — Pairwise Correlations
* -------------------------------------------------------
* In the H2 model, the triple interactions (Group x Treatment x SmallSpread)
* may correlate strongly with the corresponding double interactions
* (Group x Treatment). We compute pairwise correlations; values above
* 0.90 would indicate severe collinearity requiring caution in interpretation.
*
* Cross-group correlations (e.g. G1xTreat vs G2xTreat) are expected
* to be zero because groups are mutually exclusive by construction.

preserve

gen g1_treat    = g1 * treatmentperiod
gen g2_treat    = g2 * treatmentperiod
gen g3_treat    = g3 * treatmentperiod
gen g1_post     = g1 * postpilot
gen g2_post     = g2 * postpilot
gen g3_post     = g3 * postpilot

gen g1_treat_ss = g1 * treatmentperiod * SmallSpread
gen g2_treat_ss = g2 * treatmentperiod * SmallSpread
gen g3_treat_ss = g3 * treatmentperiod * SmallSpread
gen g1_post_ss  = g1 * postpilot * SmallSpread
gen g2_post_ss  = g2 * postpilot * SmallSpread
gen g3_post_ss  = g3 * postpilot * SmallSpread

di as text ""
di as text "========================================================"
di as text " STEP 8C: MULTICOLLINEARITY CHECK"
di as text " Pairwise correlations of H1 interaction terms:"
di as text "========================================================"
corr g1_treat g2_treat g3_treat g1_post g2_post g3_post

di as text ""
di as text "--- Pairwise correlations: H2 triple interactions vs. main interactions ---"
di as text "(Key check: gi_treat vs. gi_treat_ss — expected moderate, not severe)"
corr g1_treat g1_treat_ss g2_treat g2_treat_ss g3_treat g3_treat_ss ///
     g1_post  g1_post_ss  g2_post  g2_post_ss  g3_post  g3_post_ss

di as text "Values above 0.90 indicate potentially severe collinearity."

* Capture key correlations (double vs. triple interaction for each group/period)
* Variable order in r(C): g1_treat(1) g1_treat_ss(2) g2_treat(3) g2_treat_ss(4)
*                          g3_treat(5) g3_treat_ss(6) g1_post(7)  g1_post_ss(8)
*                          g2_post(9)  g2_post_ss(10) g3_post(11) g3_post_ss(12)
matrix MC = r(C)
local rc_g1t  = string(MC[2,1],  "%9.4f")
local rc_g2t  = string(MC[4,3],  "%9.4f")
local rc_g3t  = string(MC[6,5],  "%9.4f")
local rc_g1p  = string(MC[8,7],  "%9.4f")
local rc_g2p  = string(MC[10,9], "%9.4f")
local rc_g3p  = string(MC[12,11],"%9.4f")

* Append multicollinearity results to the same CSV
file open ac using "`outdir'/Assumption_Checks.csv", write append
file write ac `"8C,Multicollinearity (corr double vs triple),G1 treat vs G1 treat×SmallSpread,.,`rc_g1t',.,""|r|>0.90 severe collinearity""' _n
file write ac `"8C,Multicollinearity (corr double vs triple),G2 treat vs G2 treat×SmallSpread,.,`rc_g2t',.,""|r|>0.90 severe collinearity""' _n
file write ac `"8C,Multicollinearity (corr double vs triple),G3 treat vs G3 treat×SmallSpread,.,`rc_g3t',.,""|r|>0.90 severe collinearity""' _n
file write ac `"8C,Multicollinearity (corr double vs triple),G1 post vs G1 post×SmallSpread,.,`rc_g1p',.,""|r|>0.90 severe collinearity""' _n
file write ac `"8C,Multicollinearity (corr double vs triple),G2 post vs G2 post×SmallSpread,.,`rc_g2p',.,""|r|>0.90 severe collinearity""' _n
file write ac `"8C,Multicollinearity (corr double vs triple),G3 post vs G3 post×SmallSpread,.,`rc_g3p',.,""|r|>0.90 severe collinearity""' _n
file close ac

restore

*======================================================
* STEP 9: MAIN REGRESSION — H1 (AVERAGE TREATMENT EFFECT)
*======================================================
* Model: Two-Way Fixed Effects OLS (TWFE)
*
*   ln_turnover_it = alpha_i + gamma_t
*                  + beta1*(G1_i x Treat_t) + beta2*(G2_i x Treat_t)
*                  + beta3*(G3_i x Treat_t)
*                  + delta1*(G1_i x Post_t) + delta2*(G2_i x Post_t)
*                  + delta3*(G3_i x Post_t)
*                  + theta1*InvPrice_it + theta2*L_AbsRet_it + e_it
*
* alpha_i = firm fixed effects (time-invariant firm heterogeneity)
* gamma_t = date fixed effects (common daily shocks across all firms)
* Standard errors clustered at the firm level to account for
* arbitrary serial correlation within firms over time.

reghdfe ln_turnover ///
    c.g1#c.treatmentperiod c.g2#c.treatmentperiod c.g3#c.treatmentperiod ///
    c.g1#c.postpilot       c.g2#c.postpilot       c.g3#c.postpilot       ///
    Inv_Price L_abs_ret,                                                   ///
    absorb(permno date) vce(cluster permno)

* Test whether the treatment effect differs across tick-size groups
test c.g3#c.treatmentperiod = c.g1#c.treatmentperiod
test c.g3#c.treatmentperiod = c.g2#c.treatmentperiod

estimates store H1_Turnover

*======================================================
* STEP 10: MAIN REGRESSION — H2 (HETEROGENEOUS EFFECT BY SPREAD)
*======================================================
* Extends H1 by adding triple interactions with the SmallSpread indicator.
* SmallSpread_i = 1 if firm i's pre-treatment average quoted spread < $0.05
* (i.e. the new, larger tick is binding for these firms).
*
* The triple interaction beta_triple captures the ADDITIONAL (differential)
* effect of the pilot on firms whose spread was already tight enough that
* the new minimum tick is a binding constraint.

reghdfe ln_turnover ///
    c.g1#c.treatmentperiod c.g2#c.treatmentperiod c.g3#c.treatmentperiod ///
    c.g1#c.postpilot       c.g2#c.postpilot       c.g3#c.postpilot       ///
    c.g1#c.treatmentperiod#c.SmallSpread ///
    c.g2#c.treatmentperiod#c.SmallSpread ///
    c.g3#c.treatmentperiod#c.SmallSpread ///
    c.g1#c.postpilot#c.SmallSpread       ///
    c.g2#c.postpilot#c.SmallSpread       ///
    c.g3#c.postpilot#c.SmallSpread       ///
    Inv_Price L_abs_ret,                 ///
    absorb(permno date) vce(cluster permno)

estimates store H2_Turnover

*======================================================
* STEP 11: ROBUSTNESS — H1 WITH LOG VOLUME (ln_volume)
*======================================================
* ln_volume (log of raw share count) is a direct measure of the volume
* hypothesis. ln_turnover (log of volume / shares outstanding) controls
* for firm size, following Albuquerque et al. (2020). Both specifications
* are reported; convergence across the two strengthens inference.

reghdfe ln_volume ///
    c.g1#c.treatmentperiod c.g2#c.treatmentperiod c.g3#c.treatmentperiod ///
    c.g1#c.postpilot       c.g2#c.postpilot       c.g3#c.postpilot       ///
    Inv_Price L_abs_ret,                                                   ///
    absorb(permno date) vce(cluster permno)

test c.g3#c.treatmentperiod = c.g1#c.treatmentperiod
test c.g3#c.treatmentperiod = c.g2#c.treatmentperiod

estimates store H1_Volume

*======================================================
* STEP 12: ROBUSTNESS — H2 WITH LOG VOLUME (ln_volume)
*======================================================
reghdfe ln_volume ///
    c.g1#c.treatmentperiod c.g2#c.treatmentperiod c.g3#c.treatmentperiod ///
    c.g1#c.postpilot       c.g2#c.postpilot       c.g3#c.postpilot       ///
    c.g1#c.treatmentperiod#c.SmallSpread ///
    c.g2#c.treatmentperiod#c.SmallSpread ///
    c.g3#c.treatmentperiod#c.SmallSpread ///
    c.g1#c.postpilot#c.SmallSpread       ///
    c.g2#c.postpilot#c.SmallSpread       ///
    c.g3#c.postpilot#c.SmallSpread       ///
    Inv_Price L_abs_ret,                 ///
    absorb(permno date) vce(cluster permno)

estimates store H2_Volume

*======================================================
* STEP 13: EXPORT ALL REGRESSION RESULTS
*======================================================
* --- Main results: Log Turnover (H1 and H2) ---
esttab H1_Turnover H2_Turnover ///
    using "`outdir'/Regression_Results_Turnover.csv", ///
    keep(*treatmentperiod* *postpilot*) ///
    star(* 0.10 ** 0.05 *** 0.01) ///
    b(%9.4f) se(%9.4f) ///
    title("Impact of Tick Size on Log Turnover (Main Results)") ///
    replace

* --- Robustness results: Log Volume (H1 and H2) ---
esttab H1_Volume H2_Volume ///
    using "`outdir'/Regression_Results_Volume.csv", ///
    keep(*treatmentperiod* *postpilot*) ///
    star(* 0.10 ** 0.05 *** 0.01) ///
    b(%9.4f) se(%9.4f) ///
    title("Impact of Tick Size on Log Volume (Robustness Check)") ///
    replace

di as text " "
di as text "========================================================"
di as text "  All results saved to: `c(pwd)'/../results/"
di as text "--------------------------------------------------------"
di as text "  TABLES (CSV):"
di as text "    Table1_SummaryStatistics.csv"
di as text "    Assumption_Checks.csv            (Steps 8A & 8C)"
di as text "    Regression_Results_Turnover.csv   (main)"
di as text "    Regression_Results_Volume.csv     (robustness)"
di as text "--------------------------------------------------------"
di as text "  FIGURES (PNG):"
di as text "    Fig_ParallelTrends_Visual.png"
di as text "========================================================"