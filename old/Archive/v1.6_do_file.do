clear all
set more off

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
import delimited "/Users/admin/Library/Mobile Documents/com~apple~CloudDocs/Nova SBE/Research Method for Finance/Group Assignment/Data/Treatmentcontrollist.csv", delimiter(";") clear
rename *, lower

* Create mutually exclusive pilot group indicators and control indicator
gen g1 = (group == "G1")
gen g2 = (group == "G2")
gen g3 = (group == "G3")
gen control = (group == "C")

* Save cleaned treatment file for merging
save "treatment_data.dta", replace

*******************************************************
* STEP 2: LOAD WRDS DATA AND MERGE
*******************************************************
* Load daily CRSP/WRDS panel dataset and merge with treatment assignment
use "/Users/admin/Library/Mobile Documents/com~apple~CloudDocs/Nova SBE/Research Method for Finance/Group Assignment/Data/dataset.dta", clear
rename *, lower
merge m:1 permno using "treatment_data.dta"

* Keep only matched observations belonging to the SEC experiment
keep if _merge == 3
drop _merge

*******************************************************
* STEP 3: DATA CLEANING & SAMPLE CONSTRUCTION
*******************************************************
* Drop observations with missing or invalid trading data
drop if missing(vol) | missing(prc) | missing(ask) | missing(bid) | missing(shrout)
drop if vol <= 0 | prc <= 0 | shrout <= 0
drop if ask <= bid 

* 1. Mergers & Acquisitions: Drop entire firm if it ever records an M&A (codes 200-299)
bysort permno: egen has_merger = max(inrange(dlstcd, 200, 299))
drop if has_merger == 1
drop has_merger

* 2. Delistings: Drop specific daily observations flagged with delisting/drop codes (400-699)
drop if inrange(dlstcd, 400, 699)

* 3. Penny Stocks: Drop daily observations where the absolute price falls below $1
drop if abs(prc) < 1

* Restrict sample to the defined study window (Jan 1, 2016 – Apr 30, 2019)
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
* Define unified treatment period (ends Sept 28, 2018 for all)
* G1, G2, and Control use Oct 17, 2016 activation reference; G3 uses Oct 31, 2016
gen treatmentperiod = (date >= td(17oct2016) & date <= td(28sep2018))
replace treatmentperiod = (date >= td(31oct2016) & date <= td(28sep2018)) if g3 == 1

* Define pre-treatment windows to compute firm-level historical spread
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
* STEP 7: REGRESSION ANALYSIS - HYPOTHESIS 1 (AVERAGE EFFECT)
*******************************************************
* Estimate baseline DiD model using continuous interaction (#) syntax
* Includes firm and time fixed effects, clustering standard errors at firm level
reghdfe ln_turnover ///
    c.g1#c.treatmentperiod c.g2#c.treatmentperiod c.g3#c.treatmentperiod ///
    Inv_Price, ///
    absorb(permno date) vce(cluster permno)

* Test whether the volume reduction for Group 3 is statistically different from G1 and G2
test c.g3#c.treatmentperiod = c.g1#c.treatmentperiod
test c.g3#c.treatmentperiod = c.g2#c.treatmentperiod

* Store results for output
estimates store H1_Model

*******************************************************
* STEP 8: REGRESSION ANALYSIS - HYPOTHESIS 2 (HETEROGENEOUS EFFECT)
*******************************************************
* Estimate extended DiD model with triple interactions for constrained stocks (SmallSpread)
reghdfe ln_turnover ///
    c.g1#c.treatmentperiod c.g2#c.treatmentperiod c.g3#c.treatmentperiod ///
    c.g1#c.treatmentperiod#c.SmallSpread c.g2#c.treatmentperiod#c.SmallSpread c.g3#c.treatmentperiod#c.SmallSpread ///
    Inv_Price, ///
    absorb(permno date) vce(cluster permno)

* Store results for output
estimates store H2_Model

*******************************************************
* STEP 9: EXPORT REGRESSION RESULTS (OPTIONAL)
*******************************************************
* Export regression output to a formatted CSV table
esttab H1_Model H2_Model using "Regression_Results.csv", ///
    keep(*treatmentperiod*) ///
    star(* 0.10 ** 0.05 *** 0.01) ///
    b(%9.4f) se(%9.4f) ///
    title("Impact of Tick Size on Trading Volume") ///
    replace
