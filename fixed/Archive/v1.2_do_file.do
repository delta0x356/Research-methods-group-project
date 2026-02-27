clear all
set more off

*******************************************************
* INSTALL REQUIRED PACKAGES
*******************************************************
cap ssc install ftools, replace
cap ssc install reghdfe, replace
cap ssc install require, replace
mata: mata mlib index

*******************************************************
* STEP 1: PREPARE THE TREATMENT FILE
*******************************************************
import delimited "C:/Users/juli2/OneDrive/Desktop/M.Sc. Nova SBE/Subjects/Semester 2/Research Methods for Finance/Group Assignment/Coding & Data/Treatmentcontrollist.csv", delimiter(";") clear
rename *, lower
gen treatment = 0
replace treatment = 1 if inlist(group, "G1", "G2", "G3")

* Create separate binary indicators for each pilot group and for control
gen g1 = (group == "G1")
gen g2 = (group == "G2")
gen g3 = (group == "G3")
gen control = (group == "C")

save "treatment_data.dta", replace

*******************************************************
* STEP 2: LOAD WRDS DATA AND MERGE
*******************************************************
use "C:/Users/juli2/OneDrive/Desktop/M.Sc. Nova SBE/Subjects/Semester 2/Research Methods for Finance/Group Assignment/Coding & Data/dataset.dta", clear
rename *, lower

* We keep 'post' if it exists, but drop other DiD variables to start fresh [needed?]
* capture drop spread tickconstraint firm_pre_spread _merge treat_post

merge m:1 permno using "treatment_data.dta"
keep if _merge == 3
drop _merge

*******************************************************
* STEP 3: SAMPLE CONSTRUCTION & FINANCIAL VARIABLES
*******************************************************
* Clean data in one block
drop if missing(vol) | missing(prc) | missing(ask) | missing(bid)
drop if vol <= 0 | prc <= 0
drop if ask <= bid 

* Require non-missing market cap and shares outstanding for controls
drop if missing(shrout) | shrout <= 0

* Construct variables
gen ln_volume = ln(vol)
gen dollar_vol = abs(prc) * vol
gen ln_dollar_vol = ln(dollar_vol)
gen turnover = vol / shrout
gen ln_turnover = ln(turnover)

*******************************************************
* STEP 4: RECALIBRATE EXISTING TIME VARIABLE [Formulate different]
*******************************************************
* Overall sample window
keep if date >= td(01jan2016) & date <= td(30apr2019)

* Since 'post' is already in your table, we just make sure it's accurate
* This replaces the values instead of trying to 'generate' a new column
* replace post = (date >= td(03oct2016))

* Treatment period indicator for G1 & G2 (and Control, for parallel comparison)
* Turns on when 3/4 of G1/G2 stocks are activated
gen treatmentperiod_g12 = (date >= td(17oct2016) & date <= td(28sep2018))

* Treatment period indicator for G3
* Turns on when 3/4 of G3 stocks are activated
gen treatmentperiod_g3  = (date >= td(31oct2016) & date <= td(28sep2018))

* Unified Post variable:
* For G3 stocks, treatment begins Oct 31; for all others, Oct 17.
* Control stocks use the G1/G2 date as the common reference.
gen treatmentperiod = treatmentperiod_g12                          // default (G1, G2, Control)
replace treatmentperiod = treatmentperiod_g3 if g3 == 1           // G3 uses its own activation date

* post period indicator
replace post = (date >= td(29sep2018))

*******************************************************
* STEP 5: SPREAD
*******************************************************

* Calculate Quoted Spread
gen spread = ask - bid
drop if spread <= 0

* Tag the pre-treatment window used to compute firm-level average spread
* Use the common 6-month window for G1&2: April 17 – October 16, 2016
* Use the common 6-month window for G3: May 1 – October 30, 2016

gen pre_spread_window = (date >= td(17apr2016) & date <= td(16oct2016)) if  g3 == 0
replace pre_spread_window = (date >= td(01may2016) & date <= td(30oct2016)) if g3 == 1

* Compute mean spread over pre-treatment window for each firm
bysort permno: egen avg_pre_spread = mean(spread) if pre_spread_window == 1
bysort permno: egen firm_pre_spread = max(avg_pre_spread)
drop avg_pre_spread pre_spread_window

* SmallSpread: binding constraint indicator (spread strictly below $0.05)
gen SmallSpread = (firm_pre_spread < 0.05)

* Flag stocks with missing pre-spread (cannot classify constraint)
drop if missing(firm_pre_spread)

*******************************************************
* STEP 5: REGRESSIONS
*******************************************************
* H1: Baseline DiD
* reghdfe ln_turnover i.treatment#i.post, absorb(permno date) vce(cluster permno)

* H2: Heterogeneity
* reghdfe ln_turnover i.treatment#i.post#i.SmallSpread, absorb(permno date) vce(cluster permno)

*******************************************************
* STEP 6: VERIFICATION
*******************************************************
tabulate treatment post