clear all
set more off

* Automatically set working directory to the folder containing this do file
* IMPORTANT: Save the file first (Cmd+S) before clicking Execute
if "`c(do_file)'" != "" {
    local _dir = ustrregexra("`c(do_file)'", "[/\\][^/\\]*$", "")
    if "`_dir'" != "" & "`_dir'" != "`c(do_file)'" cd "`_dir'"
}
* Verify data files are accessible - exit with clear message if not found
capture confirm file "data/Treatmentcontrollist.csv"
if _rc {
    di as error "Data files not found in: `c(pwd)'/data/"
    di as error "Either: (1) Save this file first (Cmd+S) then re-run, or"
    di as error "        (2) Type in Stata command window: cd [project root folder]"
    exit 601
}

* Create results folder for all output
capture mkdir "results"

*******************************************************
* STEP 0: INSTALL REQUIRED PACKAGES
*******************************************************
cap ssc install ftools, replace
cap ssc install reghdfe, replace
cap ssc install require, replace
cap ssc install estout, replace
cap ssc install winsor2, replace
cap ssc install coefplot, replace
mata: mata mlib index

*******************************************************
* STEP 1: PREPARE THE TREATMENT FILE
*******************************************************
* Import SEC pilot treatment-control assignment file
import delimited "data/Treatmentcontrollist.csv", delimiter(",") clear
rename *, lower

* Create mutually exclusive pilot group indicators and control indicator
gen g1 = (group == "G1")
gen g2 = (group == "G2")
gen g3 = (group == "G3")
gen control = (group == "C")

* Save cleaned treatment file to a tempfile for merging
tempfile treatment_data
save `treatment_data', replace

*******************************************************
* STEP 2: LOAD WRDS DATA AND MERGE
*******************************************************
* Load daily CRSP/WRDS panel dataset and merge with treatment assignment
use "data/dataset.dta", clear
rename *, lower
merge m:1 permno using `treatment_data'

* Keep only matched observations belonging to the SEC experiment
keep if _merge == 3
drop _merge

*******************************************************
* STEP 3: DATA CLEANING & SAMPLE CONSTRUCTION
*******************************************************
* 1. Missing data: Drop observations with missing crucial trading data
drop if missing(vol) | missing(prc) | missing(ask) | missing(bid) | missing(shrout)

* 2. Zero Volume: Drop days with zero or negative volume (required for log-volume)
* Note: We don't drop negative prices because CRSP uses them for bid-ask midpoints.
drop if vol <= 0

* 3. Invalid Shares/Spreads
drop if shrout <= 0
drop if ask <= bid

* 4. Mergers & Acquisitions: Drop the ENTIRE FIRM if it ever records an M&A (codes 200-299)
bysort permno: egen has_merger = max(inrange(dlstcd, 200, 299))
drop if has_merger == 1
drop has_merger

* 5. Delistings: Drop specific DAILY OBSERVATIONS flagged with delisting/drop codes (400-599)
* We do not drop the whole firm to avoid survivorship bias prior to the delisting.
bysort permno: egen has_dropped = max(inrange(dlstcd,400,599))
drop if has_dropped == 1
drop has_dropped

* 6. Ordinary Common Shares: Keep only ordinary common stocks (share codes 10 or 11)
keep if inrange(shrcd, 10, 11)

* 7. Penny Stocks: Drop the ENTIRE FIRM if it ever trades below $1
* This ensures only healthy, non-penny stocks remain in the sample.
bysort permno: egen ever_below_1 = max(abs(prc) < 1)
drop if ever_below_1 == 1
drop ever_below_1

* 8. Price Filter: Drop individual DAILY OBSERVATIONS where the price is below $2
* This removes days with extreme noise/discreteness but keeps the firm in the sample.
drop if abs(prc) < 2

* 9. Restrict sample to the defined study window (Jan 1, 2016 – Apr 30, 2019)
keep if date >= td(01jan2016) & date <= td(30apr2019)

*******************************************************
* STEP 4: CONSTRUCT FINANCIAL & CONTROL VARIABLES
*******************************************************
* Compute daily quoted spread
gen spread = ask - bid
drop if spread <= 0

* Construct raw turnover variable
gen turnover = vol / shrout

* Construct the time-varying control variable: inverse of the daily midpoint price
gen Inv_Price = 1 / ((ask + bid) / 2)

* Winsorize continuous variables at the 1st and 99th percentiles to mitigate outlier effects
* This replaces extreme tail values with the 1st and 99th percentile values
winsor2 turnover vol spread Inv_Price, cuts(1 99) replace

* Construct logarithmic variables AFTER winsorizing the raw data
gen ln_turnover = ln(turnover)
gen ln_volume = ln(vol)

*******************************************************
* STEP 5: DEFINE TIMING & BINDING CONSTRAINT (SPREAD)
*******************************************************
* 1. Define unified treatment period (Pilot active: ends Sept 28, 2018 for all)
* G1, G2, and Control use Oct 17, 2016 activation reference; G3 uses Oct 31, 2016
gen treatmentperiod = (date >= td(17oct2016) & date <= td(28sep2018))
replace treatmentperiod = (date >= td(31oct2016) & date <= td(28sep2018)) if g3 == 1

* 2. Define post-pilot period (experiment over, back to $0.01 tick)
gen postpilot = (date > td(28sep2018))

* 3. Define pre-treatment windows to compute firm-level historical spread
* Common 6-month window for G1, G2, and Control
gen pre_window = (date >= td(17apr2016) & date <= td(16oct2016)) if g3 == 0
* Shifted 6-month window for G3
replace pre_window = (date >= td(01may2016) & date <= td(30oct2016)) if g3 == 1

* Compute firm-level maximum of the average quoted spread over the pre-period
bysort permno: egen avg_pre = mean(spread) if pre_window == 1
bysort permno: egen firm_pre_spread = max(avg_pre)
drop avg_pre pre_window

* Remove firms with missing pre-period spread data
drop if missing(firm_pre_spread)

* Create the static pre-treatment binding constraint indicator (Spread < $0.05)
gen SmallSpread = (firm_pre_spread < 0.05)

* Convenience: single group identifier for graphs
gen group_id = 0 if control == 1
replace group_id = 1 if g1 == 1
replace group_id = 2 if g2 == 1
replace group_id = 3 if g3 == 1

*******************************************************
* STEP 6: TABLE 1 - SUMMARY STATISTICS (PRE-TREATMENT)
*******************************************************
preserve

keep if date >= td(01mar2016) & date <= td(31aug2016)

label variable ln_turnover    "Log Turnover"
label variable ln_volume      "Log Volume"
label variable turnover       "Turnover"
label variable Inv_Price      "Inverse Price"
label variable spread         "Quoted Spread ($)"
label variable firm_pre_spread "Avg Pre-Treatment Spread ($)"
label variable SmallSpread    "Small Spread (< $0.05)"

estpost summarize ln_turnover ln_volume turnover Inv_Price spread firm_pre_spread SmallSpread if control == 1
est store tbl_control
estpost summarize ln_turnover ln_volume turnover Inv_Price spread firm_pre_spread SmallSpread if g1 == 1
est store tbl_g1
estpost summarize ln_turnover ln_volume turnover Inv_Price spread firm_pre_spread SmallSpread if g2 == 1
est store tbl_g2
estpost summarize ln_turnover ln_volume turnover Inv_Price spread firm_pre_spread SmallSpread if g3 == 1
est store tbl_g3

* Build combined data matrix: 7 variables × 20 stats (N Mean SD Min Max × 4 groups)
estimates restore tbl_control
matrix T = e(count)', e(mean)', e(sd)', e(min)', e(max)'
estimates restore tbl_g1
matrix T = T, e(count)', e(mean)', e(sd)', e(min)', e(max)'
estimates restore tbl_g2
matrix T = T, e(count)', e(mean)', e(sd)', e(min)', e(max)'
estimates restore tbl_g3
matrix T = T, e(count)', e(mean)', e(sd)', e(min)', e(max)'

* Write directly to Excel
putexcel set "results/Table1_SummaryStatistics.xlsx", replace sheet("Summary Statistics")

putexcel A1 = "Table 1: Summary Statistics — Pre-Treatment Period (March–August 2016)"
putexcel A3 = "Variable"

* Group labels (row 2)
putexcel B2 = "Control"          G2 = "G1 ($0.05 tick)" ///
         L2 = "G2 ($0.10 tick)"  Q2 = "G3 ($0.20 tick)"

* Column sub-headers (row 3)
putexcel B3 = "N"  C3 = "Mean"  D3 = "Std. Dev."  E3 = "Min"  F3 = "Max" ///
         G3 = "N"  H3 = "Mean"  I3 = "Std. Dev."  J3 = "Min"  K3 = "Max" ///
         L3 = "N"  M3 = "Mean"  N3 = "Std. Dev."  O3 = "Min"  P3 = "Max" ///
         Q3 = "N"  R3 = "Mean"  S3 = "Std. Dev."  T3 = "Min"  U3 = "Max"

* Variable names (column A, rows 4–10)
putexcel A4  = "Log Turnover"               A5  = "Log Volume" ///
         A6  = "Turnover"                   A7  = "Inverse Price" ///
         A8  = "Quoted Spread ($)"          A9  = "Avg Pre-Treatment Spread ($)" ///
         A10 = "Small Spread (< $0.05)"

* Data (7 rows × 20 cols) starting at B4
putexcel B4 = matrix(T), nformat(number_d4)

restore

*******************************************************
* STEP 7: REGRESSION ANALYSIS - HYPOTHESIS 1 (AVERAGE EFFECT + POST-PILOT)
*******************************************************
* Estimate baseline DiD model including the post-pilot reversal period
reghdfe ln_turnover ///
    c.g1#c.treatmentperiod c.g2#c.treatmentperiod c.g3#c.treatmentperiod ///
    c.g1#c.postpilot c.g2#c.postpilot c.g3#c.postpilot ///
    Inv_Price, ///
    absorb(permno date) vce(cluster permno)

* Test whether the volume reduction during the pilot differs across groups
test c.g3#c.treatmentperiod = c.g1#c.treatmentperiod
test c.g3#c.treatmentperiod = c.g2#c.treatmentperiod

estimates store H1_Model

*******************************************************
* STEP 8: REGRESSION ANALYSIS - HYPOTHESIS 2 (HETEROGENEOUS EFFECT + POST-PILOT)
*******************************************************
* Estimate extended DiD model with triple interactions
reghdfe ln_turnover ///
    c.g1#c.treatmentperiod c.g2#c.treatmentperiod c.g3#c.treatmentperiod ///
    c.g1#c.postpilot c.g2#c.postpilot c.g3#c.postpilot ///
    c.g1#c.treatmentperiod#c.SmallSpread c.g2#c.treatmentperiod#c.SmallSpread c.g3#c.treatmentperiod#c.SmallSpread ///
    c.g1#c.postpilot#c.SmallSpread c.g2#c.postpilot#c.SmallSpread c.g3#c.postpilot#c.SmallSpread ///
    Inv_Price, ///
    absorb(permno date) vce(cluster permno)

estimates store H2_Model

*******************************************************
* STEP 9: EXPORT REGRESSION RESULTS TO EXCEL
*******************************************************
putexcel set "results/Regression_Results.xlsx", replace sheet("Regression Results")

* Title and column headers
putexcel A1 = "Table 2: Impact of Tick Size on Trading Volume (Dep. Var.: Log Turnover)"
putexcel A3 = "Variable"
putexcel B3 = "H1: Average Effects"
putexcel E3 = "H2: Heterogeneous Effects"
putexcel B4 = "Coef."  C4 = "(SE)"
putexcel E4 = "Coef."  F4 = "(SE)"

* Row labels — main effects (rows 5–10)
putexcel A5  = "G1 × Treatment Period"
putexcel A6  = "G2 × Treatment Period"
putexcel A7  = "G3 × Treatment Period"
putexcel A8  = "G1 × Post-Pilot"
putexcel A9  = "G2 × Post-Pilot"
putexcel A10 = "G3 × Post-Pilot"

* Row labels — triple interactions, H2 only (rows 12–17)
putexcel A12 = "G1 × Treatment × SmallSpread"
putexcel A13 = "G2 × Treatment × SmallSpread"
putexcel A14 = "G3 × Treatment × SmallSpread"
putexcel A15 = "G1 × Post × SmallSpread"
putexcel A16 = "G2 × Post × SmallSpread"
putexcel A17 = "G3 × Post × SmallSpread"

* Bottom rows — model diagnostics
putexcel A19 = "Observations"
putexcel A20 = "Adj. Within R²"
putexcel A21 = "Firm FE"
putexcel A22 = "Date FE"
putexcel A23 = "Clustered SE"
putexcel C21 = "Yes"   F21 = "Yes"
putexcel C22 = "Yes"   F22 = "Yes"
putexcel C23 = "Firm"  F23 = "Firm"
putexcel A25 = "Notes: *** p<0.01, ** p<0.05, * p<0.10. Standard errors clustered at firm level in parentheses."

* Variable lists and matching row numbers (shared across both models)
local vars_main   "c.g1#c.treatmentperiod c.g2#c.treatmentperiod c.g3#c.treatmentperiod c.g1#c.postpilot c.g2#c.postpilot c.g3#c.postpilot"
local rows_main   "5 6 7 8 9 10"
local vars_triple "c.g1#c.treatmentperiod#c.SmallSpread c.g2#c.treatmentperiod#c.SmallSpread c.g3#c.treatmentperiod#c.SmallSpread c.g1#c.postpilot#c.SmallSpread c.g2#c.postpilot#c.SmallSpread c.g3#c.postpilot#c.SmallSpread"
local rows_triple "12 13 14 15 16 17"

* --- H1 Model ---
estimates restore H1_Model
putexcel B19 = e(N),          nformat("#,##0")
putexcel B20 = e(r2_within),  nformat(number_d4)

forvalues i = 1/6 {
    local v  : word `i' of `vars_main'
    local rw : word `i' of `rows_main'
    local b  = _b[`v']
    local se = _se[`v']
    local t  = abs(`b' / `se')
    if `t' > 2.576      local stars "***"
    else if `t' > 1.960 local stars "**"
    else if `t' > 1.645 local stars "*"
    else                local stars ""
    local bfmt : display %9.4f `b'
    local bfmt = strtrim("`bfmt'")
    local sefmt : display %9.4f `se'
    local sefmt = strtrim("`sefmt'")
    putexcel B`rw' = "`bfmt'`stars'"
    putexcel C`rw' = "(`sefmt')"
}

* --- H2 Model ---
estimates restore H2_Model
putexcel E19 = e(N),          nformat("#,##0")
putexcel E20 = e(r2_within),  nformat(number_d4)

* Main effects
forvalues i = 1/6 {
    local v  : word `i' of `vars_main'
    local rw : word `i' of `rows_main'
    local b  = _b[`v']
    local se = _se[`v']
    local t  = abs(`b' / `se')
    if `t' > 2.576      local stars "***"
    else if `t' > 1.960 local stars "**"
    else if `t' > 1.645 local stars "*"
    else                local stars ""
    local bfmt : display %9.4f `b'
    local bfmt = strtrim("`bfmt'")
    local sefmt : display %9.4f `se'
    local sefmt = strtrim("`sefmt'")
    putexcel E`rw' = "`bfmt'`stars'"
    putexcel F`rw' = "(`sefmt')"
}

* Triple interactions
forvalues i = 1/6 {
    local v  : word `i' of `vars_triple'
    local rw : word `i' of `rows_triple'
    local b  = _b[`v']
    local se = _se[`v']
    local t  = abs(`b' / `se')
    if `t' > 2.576      local stars "***"
    else if `t' > 1.960 local stars "**"
    else if `t' > 1.645 local stars "*"
    else                local stars ""
    local bfmt : display %9.4f `b'
    local bfmt = strtrim("`bfmt'")
    local sefmt : display %9.4f `se'
    local sefmt = strtrim("`sefmt'")
    putexcel E`rw' = "`bfmt'`stars'"
    putexcel F`rw' = "(`sefmt')"
}

*******************************************************
* STEP 11: FIGURES
*******************************************************
set scheme s1color

* -------------------------------------------------------
* Figure 1: Full-Sample Volume Trends by Group Over Time
* -------------------------------------------------------
preserve
gen ym = mofd(date)
format ym %tm
collapse (mean) mean_ln_turnover = ln_turnover, by(ym group_id)
reshape wide mean_ln_turnover, i(ym) j(group_id)
tsset ym

twoway ///
    (line mean_ln_turnover0 ym, lcolor(black)   lwidth(medthick)) ///
    (line mean_ln_turnover1 ym, lcolor(blue)    lwidth(medthick) lpattern(dash)) ///
    (line mean_ln_turnover2 ym, lcolor(red)     lwidth(medthick) lpattern(dot)) ///
    (line mean_ln_turnover3 ym, lcolor(dkgreen) lwidth(medthick) lpattern(longdash)), ///
    xline(`=ym(2016,10)', lcolor(gs10) lwidth(thin) lpattern(shortdash)) ///
    xline(`=ym(2018,9)',  lcolor(gs10) lwidth(thin) lpattern(shortdash)) ///
    legend(label(1 "Control") label(2 "G1 ($0.05)") label(3 "G2 ($0.10)") label(4 "G3 ($0.20)") ///
           cols(4) position(6) size(small)) ///
    title("Figure 1: Monthly Average Log Turnover by Group", size(medlarge)) ///
    note("Dashed vertical lines: pilot start (Oct 2016) and end (Sep 2018)", size(small)) ///
    xtitle("Month") ytitle("Mean Log Turnover") ///
    xlabel(, angle(45) labsize(small))

graph export "results/Figure1_Volume_Trends.png", replace width(1400) height(900)
restore

* -------------------------------------------------------
* Figure 2: Parallel Trends — Pre-Treatment Period
* -------------------------------------------------------
preserve
keep if date < td(17oct2016)
gen ym = mofd(date)
format ym %tm
collapse (mean) mean_ln_turnover = ln_turnover, by(ym group_id)
reshape wide mean_ln_turnover, i(ym) j(group_id)
tsset ym

twoway ///
    (line mean_ln_turnover0 ym, lcolor(black)   lwidth(medthick)) ///
    (line mean_ln_turnover1 ym, lcolor(blue)    lwidth(medthick) lpattern(dash)) ///
    (line mean_ln_turnover2 ym, lcolor(red)     lwidth(medthick) lpattern(dot)) ///
    (line mean_ln_turnover3 ym, lcolor(dkgreen) lwidth(medthick) lpattern(longdash)), ///
    legend(label(1 "Control") label(2 "G1") label(3 "G2") label(4 "G3") ///
           cols(4) position(6) size(small)) ///
    title("Figure 2: Parallel Trends — Pre-Treatment Period", size(medlarge)) ///
    subtitle("January 2016 – October 2016", size(small)) ///
    xtitle("Month") ytitle("Mean Log Turnover")

graph export "results/Figure2_Parallel_Trends.png", replace width(1400) height(900)
restore

* -------------------------------------------------------
* Figure 3: Mean Turnover by Group — Pre / During / Post
* -------------------------------------------------------
preserve
gen period = .
replace period = 1 if treatmentperiod == 0 & postpilot == 0
replace period = 2 if treatmentperiod == 1
replace period = 3 if postpilot == 1
drop if missing(period)
collapse (mean) mean_ln_turnover = ln_turnover, by(period group_id)
reshape wide mean_ln_turnover, i(period) j(group_id)

twoway ///
    (connected mean_ln_turnover0 period, lcolor(black)   mcolor(black)   lwidth(medthick)) ///
    (connected mean_ln_turnover1 period, lcolor(blue)    mcolor(blue)    lwidth(medthick) lpattern(dash)) ///
    (connected mean_ln_turnover2 period, lcolor(red)     mcolor(red)     lwidth(medthick) lpattern(dot)) ///
    (connected mean_ln_turnover3 period, lcolor(dkgreen) mcolor(dkgreen) lwidth(medthick) lpattern(longdash)), ///
    legend(label(1 "Control") label(2 "G1") label(3 "G2") label(4 "G3") ///
           cols(4) position(6) size(small)) ///
    title("Figure 3: Mean Log Turnover by Group and Period", size(medlarge)) ///
    xtitle("") ytitle("Mean Log Turnover") ///
    xlabel(1 `"Pre-Pilot"' 2 `"During Pilot"' 3 `"Post-Pilot"', noticks)

graph export "results/Figure3_Period_Comparison.png", replace width(1400) height(900)
restore

* -------------------------------------------------------
* Figure 4: Spread Distribution by Group (Pre-Treatment)
* -------------------------------------------------------
preserve
keep if treatmentperiod == 0 & postpilot == 0

twoway ///
    (kdensity spread if group_id == 0, lcolor(black)   lwidth(medthick)) ///
    (kdensity spread if group_id == 1, lcolor(blue)    lwidth(medthick) lpattern(dash)) ///
    (kdensity spread if group_id == 2, lcolor(red)     lwidth(medthick) lpattern(dot)) ///
    (kdensity spread if group_id == 3, lcolor(dkgreen) lwidth(medthick) lpattern(longdash)), ///
    legend(label(1 "Control") label(2 "G1") label(3 "G2") label(4 "G3") ///
           cols(4) position(1) size(small)) ///
    title("Figure 4: Pre-Treatment Spread Distribution by Group", size(medlarge)) ///
    xtitle("Quoted Spread ($)") ytitle("Density")

graph export "results/Figure4_Spread_Distribution.png", replace width(1400) height(900)
restore

* -------------------------------------------------------
* Figure 5: Binding Constraint Heterogeneity
* -------------------------------------------------------
preserve
gen period = .
replace period = 1 if treatmentperiod == 0 & postpilot == 0
replace period = 2 if treatmentperiod == 1
replace period = 3 if postpilot == 1
drop if missing(period)
gen treated = (g1 == 1 | g2 == 1 | g3 == 1)
collapse (mean) mean_ln_turnover = ln_turnover, by(period treated SmallSpread)

twoway ///
    (connected mean_ln_turnover period if treated==0 & SmallSpread==0, ///
        lcolor(black)  mcolor(black)  lwidth(medthick)) ///
    (connected mean_ln_turnover period if treated==0 & SmallSpread==1, ///
        lcolor(black)  mcolor(black)  lwidth(medthick) lpattern(dash)) ///
    (connected mean_ln_turnover period if treated==1 & SmallSpread==0, ///
        lcolor(blue)   mcolor(blue)   lwidth(medthick)) ///
    (connected mean_ln_turnover period if treated==1 & SmallSpread==1, ///
        lcolor(red)    mcolor(red)    lwidth(medthick)), ///
    legend(label(1 "Control, Large Spread") label(2 "Control, Small Spread") ///
           label(3 "Treated, Large Spread")  label(4 "Treated, Small Spread") ///
           cols(2) position(6) size(small)) ///
    title("Figure 5: Binding Constraint Heterogeneity", size(medlarge)) ///
    subtitle("Small Spread: pre-treatment average spread < $0.05", size(small)) ///
    xtitle("") ytitle("Mean Log Turnover") ///
    xlabel(1 `"Pre-Pilot"' 2 `"During Pilot"' 3 `"Post-Pilot"', noticks)

graph export "results/Figure5_Binding_Constraint.png", replace width(1400) height(900)
restore

* -------------------------------------------------------
* Figure 6: Volume Distribution (Pre vs. During Pilot)
* -------------------------------------------------------
preserve
keep if treatmentperiod == 0 | treatmentperiod == 1
gen period_lbl = "Pre-Pilot"
replace period_lbl = "During Pilot" if treatmentperiod == 1

twoway ///
    (kdensity ln_turnover if treatmentperiod == 0 & group_id == 0, lcolor(black)  lwidth(medthick)) ///
    (kdensity ln_turnover if treatmentperiod == 1 & group_id == 0, lcolor(black)  lwidth(medthick) lpattern(dash)) ///
    (kdensity ln_turnover if treatmentperiod == 0 & group_id == 1, lcolor(blue)   lwidth(medthick)) ///
    (kdensity ln_turnover if treatmentperiod == 1 & group_id == 1, lcolor(blue)   lwidth(medthick) lpattern(dash)) ///
    (kdensity ln_turnover if treatmentperiod == 0 & group_id == 2, lcolor(red)    lwidth(medthick)) ///
    (kdensity ln_turnover if treatmentperiod == 1 & group_id == 2, lcolor(red)    lwidth(medthick) lpattern(dash)) ///
    (kdensity ln_turnover if treatmentperiod == 0 & group_id == 3, lcolor(dkgreen) lwidth(medthick)) ///
    (kdensity ln_turnover if treatmentperiod == 1 & group_id == 3, lcolor(dkgreen) lwidth(medthick) lpattern(dash)), ///
    legend(label(1 "Control, Pre")  label(2 "Control, During") ///
           label(3 "G1, Pre")       label(4 "G1, During") ///
           label(5 "G2, Pre")       label(6 "G2, During") ///
           label(7 "G3, Pre")       label(8 "G3, During") ///
           cols(2) position(1) size(vsmall)) ///
    title("Figure 6: Log Turnover Distribution — Pre vs. During Pilot", size(medlarge)) ///
    xtitle("Log Turnover") ytitle("Density")

graph export "results/Figure6_Volume_Distribution.png", replace width(1400) height(900)
restore

* -------------------------------------------------------
* Figure 7: Coefficient Plot — H1 Model
* -------------------------------------------------------
coefplot H1_Model, ///
    keep(*treatmentperiod* *postpilot*) ///
    xline(0, lcolor(red) lwidth(thin)) ///
    title("Figure 7: Average Treatment Effects (H1 Model)", size(medlarge)) ///
    subtitle("Dependent variable: Log Turnover | Firm & Date FE | Clustered SE", size(small)) ///
    ciopts(recast(rcap) lwidth(medthick)) ///
    mcolor(navy) msize(medium) ///
    xtitle("Estimated Coefficient (95% CI)") ytitle("") ///
    xlabel(, format(%5.3f))

graph export "results/Figure7_Coefplot_H1.png", replace width(1400) height(900)

* -------------------------------------------------------
* Figure 8: Coefficient Plot — H2 Model
* -------------------------------------------------------
coefplot H2_Model, ///
    keep(*treatmentperiod* *postpilot*) ///
    xline(0, lcolor(red) lwidth(thin)) ///
    title("Figure 8: Heterogeneous Treatment Effects (H2 Model)", size(medlarge)) ///
    subtitle("Includes triple interactions with SmallSpread indicator", size(small)) ///
    ciopts(recast(rcap) lwidth(medthick)) ///
    mcolor(maroon) msize(medium) ///
    xtitle("Estimated Coefficient (95% CI)") ytitle("") ///
    xlabel(, format(%5.3f))

graph export "results/Figure8_Coefplot_H2.png", replace width(1400) height(900)

*******************************************************
* DONE
*******************************************************
di as text " "
di as text "========================================================"
di as text "  All results saved to: `c(pwd)'/results/"
di as text "--------------------------------------------------------"
di as text "  TABLES (Excel):"
di as text "    Table1_SummaryStatistics.xlsx"
di as text "    Regression_Results.xlsx"
di as text "--------------------------------------------------------"
di as text "  FIGURES (PNG, 1400x900):"
di as text "    Figure1_Volume_Trends.png"
di as text "    Figure2_Parallel_Trends.png"
di as text "    Figure3_Period_Comparison.png"
di as text "    Figure4_Spread_Distribution.png"
di as text "    Figure5_Binding_Constraint.png"
di as text "    Figure6_Volume_Distribution.png"
di as text "    Figure7_Coefplot_H1.png"
di as text "    Figure8_Coefplot_H2.png"
di as text "========================================================"
