DEPS = deps/erlzmq deps\lager

all: compile all_tests

all_tests: dialyze eunit

use_locked_config = $(wildcard USE_REBAR_LOCKED)
ifeq ($(use_locked_config),USE_REBAR_LOCKED)
  rebar_config = rebar.config.lock
else
  rebar_config = rebar.config
endif
REBAR = rebar -C $(rebar_config)

clean:
	$(REBAR) clean

allclean: depclean clean

depclean:
	@rm -rf deps

compile: $(DEPS)
	$(REBAR) compile

compile_app:
	$(REBAR) skip_deps=true compile

plt_clean:
	dialyzer --output_plt dialyzer_plt --build_plt --apps erts kernel stdlib crypto public_key ssl eunit xmerl inets mnesia snmp debugger syntax_tools

plt:
	dialyzer --output_plt dialyzer_plt --plt dialyzer_plt --add_to_plt deps/*/ebin

dialyze:
	dialyzer  --src -Wunmatched_returns -Werror_handling -Wrace_conditions -r apps/pushysim/src -I deps

#dialyzer:
#	@rm -rf apps/pushy/.eunit
# Uncomment when stubbed functions in the FSM are complete
# @dialyzer -Wrace_conditions -Wunderspecs -r apps --src

$(DEPS):
	$(REBAR) get-deps

eunit: compile
	$(REBAR) eunit apps=pushysim

eunit_app: compile_app
	$(REBAR) eunit apps=pushysim skip_deps=true

test: eunit

tags:
	@find src deps -name "*.[he]rl" -print | etags -

rel: compile rel/pushysim
rel/pushysim:
	@cd rel;$(REBAR) generate

devrel: rel
	@/bin/echo -n Symlinking deps and apps into release
	@$(foreach lib,$(wildcard apps/* deps/*), /bin/echo -n .;rm -rf rel/pushysim/lib/$(shell basename $(lib))-* \
	   && ln -sf $(abspath $(lib)) rel/pushysim/lib;)
	@/bin/echo done.
	@/bin/echo  Run \'make update\' to pick up changes in a running VM.

update: compile
	@cd rel/pushysim;bin/pushysim restart

update_app: compile_app
	@cd rel/pushysim;bin/pushysim restart

relclean:
	@rm -rf rel/pushysim

distclean: relclean
	@rm -rf deps
	$(REBAR) clean
