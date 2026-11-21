import 'package:flutter_test/flutter_test.dart';
import 'package:dosman_ujian/services/offline_quiz_service.dart';

int _countMatches(String input, RegExp regex) => regex.allMatches(input).length;

void _expectDivBalanced(String html) {
  final opens = _countMatches(html, RegExp(r'<div\b[^>]*>', caseSensitive: false));
  final closes = _countMatches(html, RegExp(r'</div>', caseSensitive: false));
  expect(opens, closes, reason: 'Unbalanced <div> tags in:\n$html');
}

void main() {
  group('OfflineQuizService HTML parser & sanitizer', () {
    test('QID 24184 (SAS Ekonomi): keeps all nested qtext divs and 5 options intact', () async {
      const ekonomiHtml = '''
<div id="question-100-13" class="que multichoice deferredfeedback notyetanswered">
  <div class="info"><h3 class="no">Question <span class="qno">13</span></h3></div>
  <div class="content">
    <div class="formulation clearfix">
      <input type="hidden" name="q100:13_:sequencecheck" value="1" />
      <div class="qtext">
        <div style="text-align:justify"><span style="font-size:12pt">Perhatikan analisis transaksi: <br></span></div>
        <div style="text-align:justify"><span style="font-size:12pt">1)&nbsp;&nbsp;&nbsp;&nbsp;&nbsp; Membeli peralatan seharga Rp20.000.000,00 dibayar Rp5.000.000,00 dan sisanya kemudian, transaksi ini berakibat harta berupa peralatan (+) di Debet Rp20.000.000,00, utang (-)&nbsp; di kredit Rp15.000.000,00 dan kas (-) di Kredit&nbsp; Rp5.000.000,00.<br>2)&nbsp;&nbsp;&nbsp;&nbsp;&nbsp; Menerima pinjaman dari bank sebesar Rp15.000.000,00 , transaksi ini berakibat&nbsp; kas (+) di Debet Rp15.000.000,00 dan utang (+) di kredit Rp15.000.000,00 <br>3)&nbsp;&nbsp;&nbsp;&nbsp;&nbsp; Membayar cicilan utang Rp3.000.000,00 , transaksi ini berakibat harta berupa&nbsp; kas (-) di Debet Rp3.000.000,00 dan utang (-) di debet sebesar Rp3.000.000,00 <br>4)&nbsp;&nbsp;&nbsp;&nbsp;&nbsp; Menerima pelunasan piutang sebesar Rp4.000.000,00 ,transaksi ini berakibat&nbsp; kas (+) di Debet Rp4.000.000,00 dan piutang (-) di Kredit Rp4.000.000,00 <br>5)&nbsp;&nbsp;&nbsp;&nbsp;&nbsp; Diselesaikan pekerjaan bengkel senilai Rp2.500.000,00,. Pembayaran dilakukan&nbsp; satu minggu kemudian, transaksi ini berakibat piutang (+) di Debet Rp2.500.000,00 dan pendapatan (+) di Kredit Rp2.500.000,00 <br></span></div>
        <div style="text-align:justify"><span style="font-size:12pt">Analisis transaksi di atas yang benar adalah .... </span></div>
      </div>
      <fieldset class="ablock no-overflow visual-scroll-x">
        <legend class="prompt h6 font-weight-normal"><span class="sr-only">Question 13</span> Select one:</legend>
        <div class="answer">
          <div class="r0"><input type="radio" name="q100:13_answer" value="0" id="q100:13_answer0" /><div data-region="answer-label" class="d-flex w-auto"><span class="answernumber">a. </span><div class="flex-fill ml-1"><span style="font-size:12pt">2, 3, dan 4 </span></div></div></div>
          <div class="r1"><input type="radio" name="q100:13_answer" value="1" id="q100:13_answer1" /><div data-region="answer-label" class="d-flex w-auto"><span class="answernumber">b. </span><div class="flex-fill ml-1"><span style="font-size:12pt">2, 4, dan 5 </span></div></div></div>
          <div class="r0"><input type="radio" name="q100:13_answer" value="2" id="q100:13_answer2" /><div data-region="answer-label" class="d-flex w-auto"><span class="answernumber">c. </span><div class="flex-fill ml-1"><span style="font-size:12pt">3, 4, dan 5</span></div></div></div>
          <div class="r1"><input type="radio" name="q100:13_answer" value="3" id="q100:13_answer3" /><div data-region="answer-label" class="d-flex w-auto"><span class="answernumber">d. </span><div class="flex-fill ml-1"><span style="font-size:12pt">1, 3, dan 4 </span></div></div></div>
          <div class="r0"><input type="radio" name="q100:13_answer" value="4" id="q100:13_answer4" /><div data-region="answer-label" class="d-flex w-auto"><span class="answernumber">e. </span><div class="flex-fill ml-1"><span style="font-size:12pt">1, 2, dan 3 </span></div></div></div>
        </div>
        <div class="qtype_multichoice_clearchoice"><input type="radio" name="q100:13_answer" value="-1" /></div>
      </fieldset>
    </div>
  </div>
</div>
''';

      final parsed = await OfflineQuizService.parseMoodleQuestionWithoutNetwork(
        {'slot': 13, 'number': '13', 'type': 'multichoice', 'sequencecheck': 1, 'html': ekonomiHtml},
        13,
      );

      expect(parsed.sequenceCheckName, 'q100:13_:sequencecheck');
      expect(parsed.answerFieldName, 'q100:13_answer');
      expect(parsed.questionHtml, contains('Perhatikan analisis transaksi:'));
      expect(parsed.questionHtml, contains('1)'));
      expect(parsed.questionHtml, contains('2)'));
      expect(parsed.questionHtml, contains('3)'));
      expect(parsed.questionHtml, contains('4)'));
      expect(parsed.questionHtml, contains('5)'));
      expect(parsed.questionHtml, contains('Analisis transaksi di atas yang benar adalah'));
      _expectDivBalanced(parsed.questionHtml);

      expect(parsed.options.length, 5);
      expect(parsed.options.map((o) => o.labelLetter).toList(), ['A', 'B', 'C', 'D', 'E']);
      expect(parsed.options[0].html, contains('2, 3, dan 4'));
      expect(parsed.options[4].html, contains('1, 2, dan 3'));
      for (final opt in parsed.options) {
        _expectDivBalanced(opt.html);
      }
    });

    test('QID 24928 (Tes SAS Kimia): balances MS Word WordSection1 divs in all options', () async {
      const kimiaHtml = '''
<div id="question-200-6" class="que multichoice deferredfeedback notyetanswered">
  <div class="content">
    <div class="formulation clearfix">
      <input type="hidden" name="q200:6_:sequencecheck" value="1" />
      <div class="qtext">
        <div class="WordSection1">
          <p class="MsoListParagraph"><span style="font-size: 11.0pt;"><!--[endif]-->Nama senyawa dari </span></p>
          <p class="MsoListParagraphCxSpLast">CH<sub>3</sub>-(CH<sub>2</sub>)<sub>2</sub> - C ≡ C - CH – CH<sub>2</sub>-CH<sub>3</sub></p>
          <p class="MsoListParagraph">CH<sub>3</sub></p>
          <p class="MsoListParagraph">Adalah….</p>
        </div>
        <p></p>
      </div>
      <fieldset class="ablock no-overflow visual-scroll-x">
        <div class="answer">
          <div class="r0"><input type="radio" name="q200:6_answer" value="0" /><div data-region="answer-label" class="d-flex w-auto"><span class="answernumber">a. </span><div class="flex-fill ml-1"><p><span>3-etil-2-metil-4-oktuna</span></p></div></div></div>
          <div class="r1"><input type="radio" name="q200:6_answer" value="1" /><div data-region="answer-label" class="d-flex w-auto"><span class="answernumber">b. </span><div class="flex-fill ml-1"><div class="WordSection1"><p><!-- [if !supportLists]--><span>6-etil-7-metil-oktuna</span></p></div></div></div></div>
          <div class="r0"><input type="radio" name="q200:6_answer" value="2" /><div data-region="answer-label" class="d-flex w-auto"><span class="answernumber">c. </span><div class="flex-fill ml-1"><div class="WordSection1"><p><!-- [if !supportLists]--><span>3-isopropil-4-oktuna</span></p></div></div></div></div>
          <div class="r1"><input type="radio" name="q200:6_answer" value="3" /><div data-region="answer-label" class="d-flex w-auto"><span class="answernumber">d. </span><div class="flex-fill ml-1"><div class="WordSection1"><p><!-- [if !supportLists]--><span>3-isopropil-4-heptuna</span></p></div></div></div></div>
          <div class="r0"><input type="radio" name="q200:6_answer" value="4" /><div data-region="answer-label" class="d-flex w-auto"><span class="answernumber">e. </span><div class="flex-fill ml-1"><div class="WordSection1"><p><span>3-isopropil-4-oktena </span></p></div></div></div></div>
        </div>
      </fieldset>
    </div>
  </div>
</div>
''';

      final parsed = await OfflineQuizService.parseMoodleQuestionWithoutNetwork(
        {'slot': 6, 'number': '6', 'type': 'multichoice', 'sequencecheck': 1, 'html': kimiaHtml},
        6,
      );

      expect(parsed.questionHtml, contains('Nama senyawa dari'));
      expect(parsed.questionHtml, contains('Adalah'));
      expect(parsed.questionHtml, isNot(contains('[endif]')));
      _expectDivBalanced(parsed.questionHtml);

      expect(parsed.options.length, 5);
      expect(parsed.options[0].html, contains('3-etil-2-metil-4-oktuna'));
      expect(parsed.options[1].html, contains('6-etil-7-metil-oktuna'));
      expect(parsed.options[2].html, contains('3-isopropil-4-oktuna'));
      expect(parsed.options[3].html, contains('3-isopropil-4-heptuna'));
      expect(parsed.options[4].html, contains('3-isopropil-4-oktena'));
      for (final opt in parsed.options) {
        expect(opt.html, isNot(contains('<!--')));
        _expectDivBalanced(opt.html);
      }
    });

    test('sanitizeFragmentHtml strips stray closing tags and closes unclosed divs', () {
      const broken = '</div><div class="WordSection1"><p>6-etil-7-metil-oktuna</p><!-- [if !supportLists]-->';
      final sanitized = OfflineQuizService.sanitizeFragmentHtml(broken);
      expect(sanitized, '<div class="WordSection1"><p>6-etil-7-metil-oktuna</p></div>');
      _expectDivBalanced(sanitized);
    });
  });
}
