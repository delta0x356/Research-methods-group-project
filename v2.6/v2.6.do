clear all
set more off

*******************************************************
* SET WORKING DIRECTORY
*******************************************************
if "`c(do_file)'" != "" {
    local _dir = ustrregexra("`c(do_file)'", "[/\\][^/\\]*$", "")
    if "`_dir'" != "" & "`_dir'" != "`c(do_file)'" cd "`_dir'"
}

* Output directory (same subfolder as input data — self-contained)
local outdir "data_and_results"

* Check required input files exist
capture confirm file "data_and_results/Treatmentcontrollist.csv"
if _rc { di as error "Missing: Treatmentcontrollist.csv" & exit 601 }

capture confirm file "data_and_results/dataset.dta"
if _rc { di as error "Missing: dataset.dta" & exit 601 }

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
import delimited "data_and_results/Treatmentcontrollist.csv", delimiter(";") clear
rename *, lower

gen g1      = (group == "G1")
gen g2      = (group == "G2")
gen g3      = (group == "G3")
gen control = (group == "C")

save "data_and_results/treatment_data.dta", replace

*******************************************************
* STEP 2: LOAD WRDS DATA AND MERGE
*******************************************************
use "data_and_results/dataset.dta", clear
rename *, lower

merge m:1 permno using "data_and_results/treatment_data.dta"
keep if _merge == 3
drop _merge

di as text "--- Steps 1-2 complete: data loaded and merged. ---"

*******************************************************
* STEP 3: DATA CLEANING & SAMPLE CONSTRUCTION
*******************************************************
* Drop missing, zero/negative volume, invalid quotes
drop if missing(vol) | missing(prc) | missing(ask) | missing(bid) | missing(shrout)
drop if vol <= 0
drop if shrout <= 0
drop if ask <= bid

* Drop entire firm if M&A event recorded (dlstcd 200-299)
bysort permno: egen has_merger = max(inrange(dlstcd, 200, 299))
drop if has_merger == 1
drop has_merger

* Drop entire firm if delisted/dropped (dlstcd 400-599)
bysort permno: egen has_dropped = max(inrange(dlstcd, 400, 599))
drop if has_dropped == 1
drop has_dropped

* Keep ordinary common shares only
keep if inrange(shrcd, 10, 11)

* No penny-stock filter: ITT framework requires keeping all assigned firms;
* extreme prices handled by winsorisation in Step 4.

* Study window: Jan 1, 2016 – Apr 30, 2019
keep if date >= td(01jan2016) & date <= td(30apr2019)

*******************************************************
* STEP 4: CONSTRUCT VARIABLES
*******************************************************
gen spread    = ask - bid
drop if spread <= 0

gen turnover  = vol / shrout
gen Inv_Price = 1 / ((ask + bid) / 2)
gen abs_ret   = abs(ret)

* Winsorise at 1st/99th percentiles, then log-transform
winsor2 turnover vol spread Inv_Price abs_ret, cuts(1 99) replace
gen ln_turnover = ln(turnover)
gen ln_volume   = ln(vol)

*******************************************************
* STEP 5: TIMING INDICATORS & BINDING CONSTRAINT
*******************************************************
* Treatment period (G3 starts two weeks later)
gen treatmentperiod = (date >= td(17oct2016) & date <= td(28sep2018))
replace treatmentperiod = (date >= td(31oct2016) & date <= td(28sep2018)) if g3 == 1

* Post-pilot period
gen postpilot = (date > td(28sep2018))

* Six-month pre-treatment window for spread classification
gen pre_window = (date >= td(17apr2016) & date <= td(16oct2016)) if g3 == 0
replace pre_window = (date >= td(01may2016) & date <= td(30oct2016)) if g3 == 1

bysort permno: egen avg_pre        = mean(spread) if pre_window == 1
bysort permno: egen firm_pre_spread = max(avg_pre)
drop avg_pre pre_window
drop if missing(firm_pre_spread)

* SmallSpread = 1 if pre-treatment avg spread < $0.05 (tick is binding)
gen SmallSpread = (firm_pre_spread < 0.05)

* Variable labels
label variable ln_turnover      "Log Turnover"
label variable ln_volume        "Log Volume"
label variable Inv_Price        "Inverse Price"
label variable abs_ret          "Absolute Daily Return"
label variable spread           "Quoted Spread"
label variable firm_pre_spread  "Avg Pre-Treatment Spread"
label variable SmallSpread      "Small Spread (pre-spread < \$0.05)"

*******************************************************
* STEP 6: TABLE 1 — SUMMARY STATISTICS (PRE-TREATMENT)
*******************************************************
* Pre-treatment window (Mar–Aug 2016), by treatment group, regression vars only
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
    cells("count mean sd min max") label ///
    mtitle("Control" "G1 (\$0.05 tick)" "G2 (\$0.10 tick)" "G3 (\$0.20 tick)") ///
    title("Table 1: Summary Statistics by Treatment Group (Pre-Treatment, Mar-Aug 2016)") ///
    note("SmallSpread = 1 if avg pre-treatment quoted spread < \$0.05.") ///
    replace
restore

*******************************************************
* STEP 7: PANEL SETUP & LAGGED RETURN
*******************************************************
* Sequential trading-day index avoids spurious lags over weekends/holidays
egen date_id = group(date)
xtset permno date_id
gen L_abs_ret = L.abs_ret

*======================================================
* STEP 8: DiD ASSUMPTION CHECKS
*======================================================
* Checks: (1) parallel pre-trends, (2) multicollinearity in H2
* Serial correlation/heteroskedasticity handled by vce(cluster permno)

* -------------------------------------------------------
* 8A: PARALLEL TRENDS — Pre-Trend F-Test
* -------------------------------------------------------
* H0: no differential trends before Oct 2016. p > 0.10 supports DiD.
preserve
keep if date < td(17oct2016)
gen quarter = qofd(date)
format quarter %tq

di as text "========================================================"
di as text " STEP 8A: PARALLEL TRENDS PRE-TEST (pre Oct 17, 2016)"
di as text "========================================================"

reghdfe ln_turnover ///
    c.g1#i.quarter c.g2#i.quarter c.g3#i.quarter, ///
    absorb(permno quarter) vce(cluster permno)

di as text "--- Joint F-tests (H0: parallel trends) ---"
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

* Export to CSV
file open ac using "`outdir'/Assumption_Checks.csv", write replace
file write ac "Step,Test,Comparison,Statistic,Value,Interpretation" _n
file write ac `"8A,Parallel Trends F-test,G1 vs Control,F-statistic (df=`df_g1'),F=`F_g1'  p=`p_g1',"p>0.10 supports parallel trends""' _n
file write ac `"8A,Parallel Trends F-test,G2 vs Control,F-statistic (df=`df_g2'),F=`F_g2'  p=`p_g2',"p>0.10 supports parallel trends""' _n
file write ac `"8A,Parallel Trends F-test,G3 vs Control,F-statistic (df=`df_g3'),F=`F_g3'  p=`p_g3',"p>0.10 supports parallel trends""' _n
file close ac

restore

* -------------------------------------------------------
* 8B: PARALLEL TRENDS — Visual Check
* -------------------------------------------------------
* Lines should move in parallel before Oct 2016 vertical marker
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
    note("Dashed lines: pilot start (Oct 2016) and end (Sep 2018)", size(small)) ///
    xtitle("Month") ytitle("Mean Log Turnover") ///
    xlabel(, angle(45) labsize(small))

graph export "`outdir'/Fig_ParallelTrends_Visual.png", replace width(1400) height(900)
restore

* -------------------------------------------------------
* 8C: MULTICOLLINEARITY CHECK — Pairwise Correlations
* -------------------------------------------------------
* Check double vs. triple interactions in H2. Concern if |r| > 0.90.
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

di as text "========================================================"
di as text " STEP 8C: MULTICOLLINEARITY CHECK"
di as text "========================================================"
corr g1_treat g2_treat g3_treat g1_post g2_post g3_post

di as text "--- H2: double vs. triple interactions ---"
corr g1_treat g1_treat_ss g2_treat g2_treat_ss g3_treat g3_treat_ss ///
     g1_post  g1_post_ss  g2_post  g2_post_ss  g3_post  g3_post_ss

* Variable order in r(C): g1_treat(1) g1_treat_ss(2) g2_treat(3) g2_treat_ss(4)
*   g3_treat(5) g3_treat_ss(6) g1_post(7) g1_post_ss(8) g2_post(9) g2_post_ss(10)
*   g3_post(11) g3_post_ss(12)
matrix MC = r(C)
local rc_g1t  = string(MC[2,1],  "%9.4f")
local rc_g2t  = string(MC[4,3],  "%9.4f")
local rc_g3t  = string(MC[6,5],  "%9.4f")
local rc_g1p  = string(MC[8,7],  "%9.4f")
local rc_g2p  = string(MC[10,9], "%9.4f")
local rc_g3p  = string(MC[12,11],"%9.4f")

file open ac using "`outdir'/Assumption_Checks.csv", write append
file write ac `"8C,Multicollinearity,G1 x Treatment  vs  G1 x Treatment x SmallSpread,Pearson r,`rc_g1t',"Concern if |r|>0.90""' _n
file write ac `"8C,Multicollinearity,G2 x Treatment  vs  G2 x Treatment x SmallSpread,Pearson r,`rc_g2t',"Concern if |r|>0.90""' _n
file write ac `"8C,Multicollinearity,G3 x Treatment  vs  G3 x Treatment x SmallSpread,Pearson r,`rc_g3t',"Concern if |r|>0.90""' _n
file write ac `"8C,Multicollinearity,G1 x Post-Pilot  vs  G1 x Post-Pilot x SmallSpread,Pearson r,`rc_g1p',"Concern if |r|>0.90""' _n
file write ac `"8C,Multicollinearity,G2 x Post-Pilot  vs  G2 x Post-Pilot x SmallSpread,Pearson r,`rc_g2p',"Concern if |r|>0.90""' _n
file write ac `"8C,Multicollinearity,G3 x Post-Pilot  vs  G3 x Post-Pilot x SmallSpread,Pearson r,`rc_g3p',"Concern if |r|>0.90""' _n
file close ac

restore

*======================================================
* STEP 9: H1 — AVERAGE TREATMENT EFFECT (ln_turnover)
*======================================================
* TWFE OLS: firm + date FE, cluster SE at firm level
reghdfe ln_turnover ///
    c.g1#c.treatmentperiod c.g2#c.treatmentperiod c.g3#c.treatmentperiod ///
    c.g1#c.postpilot       c.g2#c.postpilot       c.g3#c.postpilot       ///
    Inv_Price L_abs_ret,                                                   ///
    absorb(permno date) vce(cluster permno)

* Test equality of treatment effects across groups
test c.g3#c.treatmentperiod = c.g1#c.treatmentperiod
test c.g3#c.treatmentperiod = c.g2#c.treatmentperiod

estimates store H1_Turnover

*======================================================
* STEP 10: H2 — HETEROGENEOUS EFFECT BY SPREAD (ln_turnover)
*======================================================
* Adds triple interactions Gi x Treatment x SmallSpread.
* Gi x Treatment: effect for SmallSpread=0 (tick not binding)
* Gi x Treatment x SmallSpread: additional effect for SmallSpread=1 (tick binding)
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
* STEP 11: ROBUSTNESS — H1 WITH ln_volume
*======================================================
reghdfe ln_volume ///
    c.g1#c.treatmentperiod c.g2#c.treatmentperiod c.g3#c.treatmentperiod ///
    c.g1#c.postpilot       c.g2#c.postpilot       c.g3#c.postpilot       ///
    Inv_Price L_abs_ret,                                                   ///
    absorb(permno date) vce(cluster permno)

test c.g3#c.treatmentperiod = c.g1#c.treatmentperiod
test c.g3#c.treatmentperiod = c.g2#c.treatmentperiod

estimates store H1_Volume

*======================================================
* STEP 12: ROBUSTNESS — H2 WITH ln_volume
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
* STEP 13: EXPORT RESULTS
*======================================================
esttab H1_Turnover H2_Turnover ///
    using "`outdir'/Regression_Results_Turnover.csv", ///
    keep(*treatmentperiod* *postpilot*) ///
    star(* 0.10 ** 0.05 *** 0.01) b(%9.4f) se(%9.4f) ///
    mtitle("H1: Average Effect" "H2: Heterogeneous by Spread") ///
    varlabels( ///
        c.g1#c.treatmentperiod                "G1 x Treatment" ///
        c.g2#c.treatmentperiod                "G2 x Treatment" ///
        c.g3#c.treatmentperiod                "G3 x Treatment" ///
        c.g1#c.postpilot                      "G1 x Post-Pilot" ///
        c.g2#c.postpilot                      "G2 x Post-Pilot" ///
        c.g3#c.postpilot                      "G3 x Post-Pilot" ///
        c.g1#c.treatmentperiod#c.SmallSpread  "G1 x Treatment x SmallSpread" ///
        c.g2#c.treatmentperiod#c.SmallSpread  "G2 x Treatment x SmallSpread" ///
        c.g3#c.treatmentperiod#c.SmallSpread  "G3 x Treatment x SmallSpread" ///
        c.g1#c.postpilot#c.SmallSpread        "G1 x Post-Pilot x SmallSpread" ///
        c.g2#c.postpilot#c.SmallSpread        "G2 x Post-Pilot x SmallSpread" ///
        c.g3#c.postpilot#c.SmallSpread        "G3 x Post-Pilot x SmallSpread" ///
    ) ///
    title("Impact of Tick Size on Log Turnover") ///
    note("Firm and date FE absorbed. Clustered SE at firm level." ///
         "H1: Gi x Treatment = avg effect. H2: Gi x Treatment = effect for SmallSpread=0;" ///
         "Gi x Treatment x SmallSpread = additional effect for SmallSpread=1 (tick binding, pre-spread < \$0.05)." ///
         "* p<0.10  ** p<0.05  *** p<0.01") ///
    replace

esttab H1_Volume H2_Volume ///
    using "`outdir'/Regression_Results_Volume.csv", ///
    keep(*treatmentperiod* *postpilot*) ///
    star(* 0.10 ** 0.05 *** 0.01) b(%9.4f) se(%9.4f) ///
    mtitle("H1: Average Effect" "H2: Heterogeneous by Spread") ///
    varlabels( ///
        c.g1#c.treatmentperiod                "G1 x Treatment" ///
        c.g2#c.treatmentperiod                "G2 x Treatment" ///
        c.g3#c.treatmentperiod                "G3 x Treatment" ///
        c.g1#c.postpilot                      "G1 x Post-Pilot" ///
        c.g2#c.postpilot                      "G2 x Post-Pilot" ///
        c.g3#c.postpilot                      "G3 x Post-Pilot" ///
        c.g1#c.treatmentperiod#c.SmallSpread  "G1 x Treatment x SmallSpread" ///
        c.g2#c.treatmentperiod#c.SmallSpread  "G2 x Treatment x SmallSpread" ///
        c.g3#c.treatmentperiod#c.SmallSpread  "G3 x Treatment x SmallSpread" ///
        c.g1#c.postpilot#c.SmallSpread        "G1 x Post-Pilot x SmallSpread" ///
        c.g2#c.postpilot#c.SmallSpread        "G2 x Post-Pilot x SmallSpread" ///
        c.g3#c.postpilot#c.SmallSpread        "G3 x Post-Pilot x SmallSpread" ///
    ) ///
    title("Impact of Tick Size on Log Volume — Robustness") ///
    note("Firm and date FE absorbed. Clustered SE at firm level." ///
         "SmallSpread = 1 if avg pre-treatment quoted spread < \$0.05." ///
         "* p<0.10  ** p<0.05  *** p<0.01") ///
    replace

di as text "All results saved to: `c(pwd)'/data_and_results/"
