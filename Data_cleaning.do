* --------------------------------------------------------
* STEP 1: PREPARE THE TREATMENT FILE
* --------------------------------------------------------

import delimited "/Users/admin/Library/Mobile Documents/com~apple~CloudDocs/Nova SBE/Research Method for Finance/Group Assignment/Data/Treatmentcontrollist.csv", delimiter(";") clear

* Force ALL variable names to lowercase to avoid merge conflicts
rename *, lower

* Create the treatment dummy variable
gen Treatment = 0
replace Treatment = 1 if group == "G1" | group == "G2" | group == "G3"

* Save the file (now we are absolutely sure the key is called "permno")
save "treatment_data.dta", replace

* --------------------------------------------------------
* STEP 2: LOAD THE WRDS DATASET AND MERGE
* --------------------------------------------------------

use "/Users/admin/Library/Mobile Documents/com~apple~CloudDocs/Nova SBE/Research Method for Finance/Group Assignment/Data/dataset.dta", clear

* Force ALL variable names to lowercase here as well!
rename *, lower

* Merge the two dataset
merge m:1 permno using "treatment_data.dta"

* Keep only the successfully matched observations and clean up
keep if _merge == 3
drop _merge

* --------------------------------------------------------
* STEP 3: CREATE THE DIFFERENCE-IN-DIFFERENCES VARIABLES
* --------------------------------------------------------

* Create the Post variable (from October 3, 2016 onwards)
gen Post = 0
replace Post = 1 if date >= 20161003

* Create the interaction term for the DiD estimator
gen Treat_Post = Treatment * Post
