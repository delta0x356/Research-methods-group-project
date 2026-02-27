****************************************************
* Tick Size Pilot – Group Assignment
* Empirical Implementation
****************************************************

clear all
set more off

*--------------------------------------------------
* 1. Set working directory
*--------------------------------------------------
* Replace with your own folder path
cd "C:\Users\Antonio Rocha\Downloads"

*--------------------------------------------------
* 2. Load dataset
*--------------------------------------------------
use "dataset.dta", clear

* Inspect structure
describe

*--------------------------------------------------
* 3. Restrict sample period
* January 1, 2016 – April 30, 2019
*--------------------------------------------------
keep if date >= td(01jan2016) & date <= td(30apr2019)

*--------------------------------------------------
* 4. Data cleaning
*--------------------------------------------------

* Remove missing observations in key variables
drop if missing(vol, prc, bid, ask, Treatment, Post)

* Ensure price is positive (CRSP sometimes stores it as negative)
replace prc = abs(prc)

* Remove non-positive volume (cannot take logs)
drop if vol <= 0

*--------------------------------------------------
* 5. Construct dependent variable
*--------------------------------------------------

gen log_volume = ln(vol)

*--------------------------------------------------
* 6. Winsorize log_volume at 1% and 99%
*--------------------------------------------------

summ log_volume, detail

scalar p1 = r(p1)
scalar p99 = r(p99)

replace log_volume = p1 if log_volume < p1
replace log_volume = p99 if log_volume > p99