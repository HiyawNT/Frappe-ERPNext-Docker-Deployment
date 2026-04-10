FROM frappe/erpnext:version-16

USER frappe

# Add custom apps / official apps here 
# this is an example but NEVER EVER use this in Prod Always specify a version becuase their default branch (develop)
# Is all kinds of Unpredictable
RUN bench get-app payments

