* generic180_mos.inc - device cards of generic180.lib (needs dvn dvp mun mup)
.model nch nmos level=49 version=3.3 tnom=27 mobmod=1 capmod=3
+ tox=4.1e-9 xj=1e-7 nch=2.35e17 vth0={0.37+dvn} k1=0.58 k2=0.002 k3=1e-3 k3b=0.6
+ w0=1e-7 nlx=1.9e-7 dvt0=1.2 dvt1=0.35 dvt2=0.05 dvt0w=0 dvt1w=0 dvt2w=0
+ u0={260*mun} ua=-1.4e-9 ub=2.3e-18 uc=5e-11 vsat=1.0e5 a0=1.9 ags=0.42
+ b0=-1e-8 b1=-1e-7 keta=-0.01 a1=0 a2=1 rdsw=105 prwg=0.5 prwb=-0.2 wr=1
+ wint=0 lint=1.5e-8 dwg=-5e-9 dwb=9e-9 voff=-0.09 nfactor=2.2 cit=0
+ cdsc=2.4e-4 cdscd=0 cdscb=0 eta0=2.5e-3 etab=-1e-5 dsub=0.02 pclm=0.75
+ pdiblc1=0.2 pdiblc2=2e-3 pdiblcb=-0.1 drout=0.6 pscbe1=8e9 pscbe2=1e-8
+ pvag=0 delta=0.01 rsh=6.8 prt=0 ute=-1.5 kt1=-0.11 kt1l=0 kt2=0.022
+ ua1=4.3e-9 ub1=-7.6e-18 uc1=-5.6e-11 at=3.3e4 xpart=0.5
+ cgdo=3.7e-10 cgso=3.7e-10 cgbo=1e-12 cj=9.7e-4 pb=0.8 mj=0.38
+ cjsw=2.5e-10 pbsw=0.8 mjsw=0.11 cjswg=3.3e-10 pbswg=0.8 mjswg=0.11
+ noimod=1 kf=2e-26 af=1 ef=1
.model pch pmos level=49 version=3.3 tnom=27 mobmod=1 capmod=3
+ tox=4.1e-9 xj=1e-7 nch=4.1e17 vth0={-0.39-dvp} k1=0.55 k2=0.03 k3=0 k3b=1.2
+ w0=1e-6 nlx=1.2e-7 dvt0=0.6 dvt1=0.25 dvt2=0.1 dvt0w=0 dvt1w=0 dvt2w=0
+ u0={105*mup} ua=1.4e-9 ub=1e-21 uc=-1e-10 vsat=1.6e5 a0=1.6 ags=0.38
+ b0=1e-7 b1=1e-6 keta=0.02 a1=0.5 a2=0.4 rdsw=310 prwg=0.4 prwb=-0.1 wr=1
+ wint=0 lint=2.0e-8 dwg=-3e-8 dwb=-1e-9 voff=-0.1 nfactor=1.8 cit=0
+ cdsc=2.4e-4 cdscd=0 cdscb=0 eta0=0.1 etab=-0.06 dsub=0.8 pclm=1.4
+ pdiblc1=0.002 pdiblc2=-1e-5 pdiblcb=-1e-3 drout=0.001 pscbe1=6e9
+ pscbe2=5e-10 pvag=1.2 delta=0.01 rsh=7.5 prt=0 ute=-1.5 kt1=-0.11 kt1l=0
+ kt2=0.022 ua1=4.3e-9 ub1=-7.6e-18 uc1=-5.6e-11 at=3.3e4 xpart=0.5
+ cgdo=3.1e-10 cgso=3.1e-10 cgbo=1e-12 cj=1.15e-3 pb=0.85 mj=0.41
+ cjsw=2.0e-10 pbsw=0.85 mjsw=0.33 cjswg=4.2e-10 pbswg=0.85 mjswg=0.33
+ noimod=1 kf=1e-27 af=1 ef=1
* 3.3 V thick-oxide devices (tox 7 nm, Lmin 0.35 um): input stages on RX_VDD
.model nch33 nmos level=49 version=3.3 tnom=27 mobmod=1 capmod=3
+ tox=7.0e-9 xj=1.5e-7 nch=1.7e17 vth0={0.64+dvn} k1=0.80 k2=-0.02 k3=1e-3 k3b=0.6
+ w0=1e-7 nlx=1.5e-7 dvt0=1.5 dvt1=0.4 dvt2=0.0 dvt0w=0 dvt1w=0 dvt2w=0
+ u0={380*mun} ua=-1e-9 ub=2.0e-18 uc=5e-11 vsat=0.9e5 a0=1.2 ags=0.3
+ b0=0 b1=0 keta=-0.02 a1=0 a2=1 rdsw=300 prwg=0.3 prwb=-0.1 wr=1
+ wint=0 lint=3e-8 dwg=0 dwb=0 voff=-0.1 nfactor=1.5 cit=0
+ cdsc=2.4e-4 cdscd=0 cdscb=0 eta0=0.02 etab=-0.01 dsub=0.4 pclm=1.0
+ pdiblc1=0.1 pdiblc2=1e-3 pdiblcb=-0.05 drout=0.5 pscbe1=8e9 pscbe2=1e-7
+ pvag=0 delta=0.01 rsh=6.8 prt=0 ute=-1.5 kt1=-0.15 kt1l=0 kt2=0.022
+ ua1=4.3e-9 ub1=-7.6e-18 uc1=-5.6e-11 at=3.3e4 xpart=0.5
+ cgdo=3.0e-10 cgso=3.0e-10 cgbo=1e-12 cj=8.5e-4 pb=0.8 mj=0.36
+ cjsw=2.3e-10 pbsw=0.8 mjsw=0.11 cjswg=3.0e-10 pbswg=0.8 mjswg=0.11
+ noimod=1 kf=2e-26 af=1 ef=1
.model pch33 pmos level=49 version=3.3 tnom=27 mobmod=1 capmod=3
+ tox=7.0e-9 xj=1.5e-7 nch=2.5e17 vth0={-0.58-dvp} k1=0.70 k2=0.01 k3=0 k3b=1.0
+ w0=1e-6 nlx=1.2e-7 dvt0=0.8 dvt1=0.3 dvt2=0.05 dvt0w=0 dvt1w=0 dvt2w=0
+ u0={130*mup} ua=1.4e-9 ub=1e-21 uc=-1e-10 vsat=1.2e5 a0=1.2 ags=0.3
+ b0=0 b1=0 keta=0.0 a1=0.5 a2=0.4 rdsw=700 prwg=0.3 prwb=-0.1 wr=1
+ wint=0 lint=4e-8 dwg=0 dwb=0 voff=-0.1 nfactor=1.5 cit=0
+ cdsc=2.4e-4 cdscd=0 cdscb=0 eta0=0.05 etab=-0.03 dsub=0.6 pclm=1.2
+ pdiblc1=0.01 pdiblc2=1e-4 pdiblcb=-1e-3 drout=0.1 pscbe1=6e9
+ pscbe2=5e-10 pvag=1.0 delta=0.01 rsh=7.5 prt=0 ute=-1.5 kt1=-0.15 kt1l=0
+ kt2=0.022 ua1=4.3e-9 ub1=-7.6e-18 uc1=-5.6e-11 at=3.3e4 xpart=0.5
+ cgdo=2.7e-10 cgso=2.7e-10 cgbo=1e-12 cj=1.0e-3 pb=0.85 mj=0.40
+ cjsw=2.0e-10 pbsw=0.85 mjsw=0.33 cjswg=3.8e-10 pbswg=0.85 mjswg=0.33
+ noimod=1 kf=1e-27 af=1 ef=1
