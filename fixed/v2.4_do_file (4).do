clear all
set more off

* Automatically set working directory to the folder containing this do file
local dofile_path "`c(do_file)'"
local dofile_dir = ustrregexra("`dofile_path'", "[/\\][^/\\]*$", "")
cd "`dofile_dir'"

*******************************************************
* STEP 0: INSTALL REQUIRED PACKAGES
*******************************************************
cap ssc install ftools, replace
cap ssc install reghdfe, replace
cap ssc install require, replace
cap ssc install estout, replace
cap ssc install winsor2, replace
mata: mata mlib index

*******************************************************
* STEP 1: PREPARE THE TREATMENT FILE
*******************************************************
* Import SEC pilot treatment-control assignment file
import delimited "Treatmentcontrollist.csv", delimiter(",") clear
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
use "dataset.dta", clear
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
* 1. Define unified treatment period (Pilot attivo: ends Sept 28, 2018 for all)
* G1, G2, and Control use Oct 17, 2016 activation reference; G3 uses Oct 31, 2016
gen treatmentperiod = (date >= td(17oct2016) & date <= td(28sep2018))
replace treatmentperiod = (date >= td(31oct2016) & date <= td(28sep2018)) if g3 == 1

* 2. NEW: Define post-pilot period (The experiment is over, back to £0.01)
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

*******************************************************
* STEP 6: TABLE 1 - SUMMARY STATISTICS (PRE-TREATMENT)
*******************************************************
preserve

* Restrict to the standard pre-treatment window (Mar 1 – Aug 31, 2016)
keep if date >= td(01mar2016) & date <= td(31aug2016)

* Generate summary statistics for Control Group
estpost summarize ln_turnover ln_volume turnover Inv_Price spread firm_pre_spread SmallSpread if control == 1
est store control

* Generate summary statistics for Group 1
estpost summarize ln_turnover ln_volume turnover Inv_Price spread firm_pre_spread SmallSpread if g1 == 1
est store g1

* Generate summary statistics for Group 2
estpost summarize ln_turnover ln_volume turnover Inv_Price spread firm_pre_spread SmallSpread if g2 == 1
est store g2

* Generate summary statistics for Group 3
estpost summarize ln_turnover ln_volume turnover Inv_Price spread firm_pre_spread SmallSpread if g3 == 1
est store g3

* Export Table 1 to CSV
esttab control g1 g2 g3 using "Table1_SummaryStatistics.csv", cells("count mean sd min max") label replace

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

* Test whether the volume reduction during the pilot is statistically different among groups
test c.g3#c.treatmentperiod = c.g1#c.treatmentperiod
test c.g3#c.treatmentperiod = c.g2#c.treatmentperiod

* Store results for output
estimates store H1_Model

*******************************************************
* STEP 8: REGRESSION ANALYSIS - HYPOTHESIS 2 (HETEROGENEOUS EFFECT + POST-PILOT)
*******************************************************
* Estimate extended DiD model with triple interactions, including the post-pilot reversal
reghdfe ln_turnover ///
    c.g1#c.treatmentperiod c.g2#c.treatmentperiod c.g3#c.treatmentperiod ///
    c.g1#c.postpilot c.g2#c.postpilot c.g3#c.postpilot ///
    c.g1#c.treatmentperiod#c.SmallSpread c.g2#c.treatmentperiod#c.SmallSpread c.g3#c.treatmentperiod#c.SmallSpread ///
    c.g1#c.postpilot#c.SmallSpread c.g2#c.postpilot#c.SmallSpread c.g3#c.postpilot#c.SmallSpread ///
    Inv_Price, ///
    absorb(permno date) vce(cluster permno)

* Store results for output
estimates store H2_Model

*******************************************************
* STEP 9: EXPORT REGRESSION RESULTS
*******************************************************
esttab H1_Model H2_Model using "Regression_Results.csv", ///
    keep(*treatmentperiod* *postpilot*) ///
    star(* 0.10 ** 0.05 *** 0.01) ///
    b(%9.4f) se(%9.4f) ///
    title("Impact of Tick Size on Trading Volume") ///
    replace
