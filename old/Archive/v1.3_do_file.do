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
* Import SEC pilot treatment-control assignment file
import delimited "C:/Users/juli2/OneDrive/Desktop/M.Sc. Nova SBE/Subjects/Semester 2/Research Methods for Finance/Group Assignment/Coding & Data/Treatmentcontrollist.csv", delimiter(";") clear
rename *, lower

* Create overall treatment indicator (1 = any pilot group, 0 = control)
gen treatment = 0
replace treatment = 1 if inlist(group, "G1", "G2", "G3")

* Create mutually exclusive group indicators
gen g1 = (group == "G1")
gen g2 = (group == "G2")
gen g3 = (group == "G3")
gen control = (group == "C")

* Save cleaned treatment file (one observation per firm)
save "treatment_data.dta", replace

*******************************************************
* STEP 2: LOAD WRDS DATA AND MERGE
*******************************************************
* Load daily CRSP/WRDS panel dataset (firm-date observations)
use "C:/Users/juli2/OneDrive/Desktop/M.Sc. Nova SBE/Subjects/Semester 2/Research Methods for Finance/Group Assignment/Coding & Data/dataset.dta", clear
rename *, lower

* Merge firm-level treatment assignment into daily panel
* m:1 because master dataset has many observations per permno (daily),
* while treatment file has one observation per permno
merge m:1 permno using "treatment_data.dta"

* Keep only firms that are part of the SEC experiment (matched observations)
keep if _merge == 3
drop _merge

*******************************************************
* STEP 3: SAMPLE CONSTRUCTION & FINANCIAL VARIABLES
*******************************************************
* Remove observations with missing or invalid key variables
drop if missing(vol) | missing(prc) | missing(ask) | missing(bid)
drop if vol <= 0 | prc <= 0
drop if ask <= bid 

* Require valid shares outstanding for turnover calculation
drop if missing(shrout) | shrout <= 0

* Construct outcome variables
gen ln_volume = ln(vol)
gen dollar_vol = abs(prc) * vol
gen ln_dollar_vol = ln(dollar_vol)
gen turnover = vol / shrout
gen ln_turnover = ln(turnover)

*******************************************************
* STEP 4: DEFINE SAMPLE WINDOW AND TREATMENT TIMING
*******************************************************
* Restrict sample to assignment period (Jan 1, 2016 – Apr 30, 2019)
keep if date >= td(01jan2016) & date <= td(30apr2019)

* Define experiment termination (post-pilot period)
gen post = (date >= td(29sep2018))

* Define pilot activation window for G1 & G2 stocks
* Turns on when 3/4 of G1/G2 stocks are activated
gen treatmentperiod_g12 = (date >= td(17oct2016) & date <= td(28sep2018))

* Define pilot activation window for G3 stocks
* Turns on when 3/4 of G3 stocks are activated
gen treatmentperiod_g3  = (date >= td(31oct2016) & date <= td(28sep2018))

* Unified treatment-period indicator:
* - G1, G2, and Control use Oct 17 activation reference
* - G3 uses Oct 31 activation reference
gen treatmentperiod = treatmentperiod_g12                      // default (G1, G2, Control)
replace treatmentperiod = treatmentperiod_g3 if g3 == 1        // G3 uses its own activation date

* Post indicator (pilot ends September 28, 2018)
gen post = (date >= td(29sep2018))

*******************************************************
* STEP 5: CONSTRUCT PRE-TREATMENT SPREAD MEASURE
*******************************************************
* Compute daily quoted spread
gen spread = ask - bid
drop if spread <= 0

* Tag the pre-treatment window used to compute firm-level average spread
* Use the common 6-month window for G1&2: April 17 – October 16, 2016
* Use the common 6-month window for G3: May 1 – October 30, 2016
gen pre_spread_window = (date >= td(17apr2016) & date <= td(16oct2016)) if  g3 == 0 & control == 0
replace pre_spread_window = (date >= td(01may2016) & date <= td(30oct2016)) if g3 == 1

* Compute firm-level average quoted spread over the relevant pre-treatment window
bysort permno: egen avg_pre_spread = mean(spread) if pre_spread_window == 1

* Propagate firm-level average across all observations of the firm
bysort permno: egen firm_pre_spread = max(avg_pre_spread)
drop avg_pre_spread pre_spread_window

* Define binding-constraint indicator:
* SmallSpread = 1 if firm's average pre-pilot spread < $0.05
* These firms are expected to be more strongly affected by the tick increase
gen SmallSpread = (firm_pre_spread < 0.05)

* Remove firms that cannot be classified due to missing pre-period data
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
*tabulate treatment post