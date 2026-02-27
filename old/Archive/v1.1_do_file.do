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
save "treatment_data.dta", replace

*******************************************************
* STEP 2: LOAD WRDS DATA AND MERGE
*******************************************************
use "C:/Users/juli2/OneDrive/Desktop/M.Sc. Nova SBE/Subjects/Semester 2/Research Methods for Finance/Group Assignment/Coding & Data/dataset.dta", clear
rename *, lower

* We keep 'post' if it exists, but drop other DiD variables to start fresh
capture drop spread tickconstraint firm_pre_spread _merge treat_post

merge m:1 permno using "treatment_data.dta"
keep if _merge == 3
drop _merge

*******************************************************
* STEP 3: SAMPLE CONSTRUCTION & FINANCIAL VARIABLES
*******************************************************
* Clean data in one block
drop if missing(vol) | prc <= 0 | vol == 0

* Construct variables
gen ln_volume = ln(vol)
gen dollar_vol = abs(prc) * vol
gen ln_dollar_vol = ln(dollar_vol)
gen turnover = vol / shrout
gen ln_turnover = ln(turnover)

*******************************************************
* STEP 4: RECALIBRATE EXISTING POST VARIABLE
*******************************************************
* Since 'post' is already in your table, we just make sure it's accurate
* This replaces the values instead of trying to 'generate' a new column
replace post = (date >= td(03oct2016))

* Calculate Quoted Spread
gen spread = ask - bid
drop if spread <= 0

* Identify Tick-Constrained firms (Pre-period)
bysort permno: egen avg_pre_spread = mean(spread) if post == 0
bysort permno: egen firm_pre_spread = max(avg_pre_spread)
drop avg_pre_spread
gen tickconstraint = (firm_pre_spread <= 0.03)

*******************************************************
* STEP 5: REGRESSIONS
*******************************************************
* H1: Baseline DiD
reghdfe ln_turnover i.treatment#i.post, absorb(permno date) vce(cluster permno)

* H2: Heterogeneity
reghdfe ln_turnover i.treatment#i.post#i.tickconstraint, absorb(permno date) vce(cluster permno)

*******************************************************
* STEP 6: VERIFICATION
*******************************************************
tabulate treatment post