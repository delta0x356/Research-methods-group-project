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
* Drop observations with missing or invalid basic trading data 
drop if missing(vol) | missing(prc) | missing(ask) | missing(bid)
drop if vol <= 0 | prc <= 0
drop if ask <= bid 

* Drop observations with missing or invalid shares outstanding 
drop if missing(shrout) | shrout <= 0

* 1. Mergers & Acquisitions (M&A)
* Create a dummy variable equal to 1 if the firm (permno) ever records an M&A event (codes 200 to 299)
bysort permno: egen has_merger = max(inrange(delisted_code, 200, 299))

* Drop all historical and future observations for any firm that experiences an M&A
drop if has_merger == 1
drop has_merger

* 2. Delistings and Drops
* Drop specific daily observations where the stock is marked with a delisting or dropped code (codes 400 to 699)
drop if inrange(delisted_code, 400, 699)

* 3. Penny Stocks
* Drop specific daily observations where the absolute closing price falls below $1
drop if abs(prc) < 1

* Construct outcome variables
gen ln_volume = ln(vol)
gen dollar_vol = abs(prc) * vol
gen ln_dollar_vol = ln(dollar_vol)
gen turnover = vol / shrout
gen ln_turnover = ln(turnover)
* Log stock price (controls for price scaling; use abs due to CRSP sign convention)
gen ln_price = ln(abs(prc))

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
* TABLE 1: SUMMARY STATISTICS (PRE-TREATMENT ONLY)
*******************************************************
preserve

* Keep pre-treatment window (March 1 – August 31, 2016)
keep if date >= td(01mar2016) & date <= td(31aug2016)

* Keep only variables used in the analysis
keep permno group control g1 g2 g3 ///
     ln_turnover ln_volume turnover ///
     ln_price ret spread firm_pre_spread SmallSpread

*******************************************************
* PANEL A: CONTROL GROUP
*******************************************************
estpost summarize ln_turnover ln_volume turnover ///
                  ln_price ret spread firm_pre_spread ///
                  if control == 1
est store control

*******************************************************
* PANEL B: GROUP 1
*******************************************************
estpost summarize ln_turnover ln_volume turnover ///
                  ln_price ret spread firm_pre_spread ///
                  if g1 == 1
est store g1

*******************************************************
* PANEL C: GROUP 2
*******************************************************
estpost summarize ln_turnover ln_volume turnover ///
                  ln_price ret spread firm_pre_spread ///
                  if g2 == 1
est store g2

*******************************************************
* PANEL D: GROUP 3
*******************************************************
estpost summarize ln_turnover ln_volume turnover ///
                  ln_price ret spread firm_pre_spread ///
                  if g3 == 1
est store g3

*******************************************************
* EXPORT TABLE
*******************************************************
esttab control g1 g2 g3 ///
    using "Table1_SummaryStatistics.csv", ///
    cells("count mean sd min max") ///
    label replace

restore

*******************************************************
* STEP 6: DEFINE DiD INTERACTION TERMS (H1)
*******************************************************
gen g1_treat = g1 * treatmentperiod
gen g2_treat = g2 * treatmentperiod
gen g3_treat = g3 * treatmentperiod

*******************************************************
* STEP 7: POWER CONTROLS
*******************************************************
* Declare panel structure (required for lag operator)
xtset permno date

* Lagged absolute return (attention / volatility persistence)
gen abs_ret = abs(ret)
gen L_abs_ret = L.abs_ret

* Drop first firm observation where lag is missing
drop if missing(L_abs_ret)

*******************************************************
* STEP 8: BASELINE DiD REGRESSION (H1)
*******************************************************
reghdfe ln_turnover ///
    g1_treat g2_treat g3_treat ///
    , absorb(permno date) ///
    vce(cluster permno)

*******************************************************
* STEP 9: EXTENDED MODEL WITH CONTROLS
*******************************************************
reghdfe ln_turnover ///
    g1_treat g2_treat g3_treat ///
    ln_price L_abs_ret ///
    , absorb(permno date) ///
    vce(cluster permno)

*******************************************************
* STEP 10: TEST WHETHER GROUP 3 EFFECT IS LARGER
*******************************************************
test g3_treat = g1_treat
test g3_treat = g2_treat