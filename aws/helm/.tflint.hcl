plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

rule "terraform_documented_variables" {
  enabled = true
}

rule "terraform_documented_outputs" {
  enabled = true
}

# CONVENTIONS.md section 2: a module version is exact, never a range.
rule "terraform_module_version" {
  enabled = true
  exact   = true
}
